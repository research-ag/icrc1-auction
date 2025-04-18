import Int "mo:base/Int";
import Nat64 "mo:base/Nat64";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import TokenHandler "mo:token_handler";

import CkBtcAddress "mo:ckbtc_address";

module {

  type Utxo = {
    outpoint : { txid : [Nat8]; vout : Nat32 };
    value : Nat64;
    height : Nat32;
  };

  type PendingUtxo = {
    outpoint : { txid : [Nat8]; vout : Nat32 };
    value : Nat64;
    confirmations : Nat32;
  };

  type SuspendedReason = {
    #ValueTooSmall;
    #Quarantined;
  };

  type SuspendedUtxo = {
    utxo : Utxo;
    reason : SuspendedReason;
    earliest_retry : Nat64;
  };

  public type UtxoStatus = {
    #ValueTooSmall : Utxo;
    #Tainted : Utxo;
    #Checked : Utxo;
    #Minted : {
      block_index : Nat64;
      minted_amount : Nat64;
      utxo : Utxo;
    };
  };

  public type UpdateBalanceError = {
    #NoNewUtxos : {
      current_confirmations : ?Nat32;
      required_confirmations : Nat32;
      pending_utxos : ?[PendingUtxo];
      suspended_utxos : ?[SuspendedUtxo];
    };
    #AlreadyProcessing;
    #TemporarilyUnavailable : Text;
    #GenericError : { error_message : Text; error_code : Nat64 };
  };

  public type RetrieveBtcWithApprovalError = {
    #MalformedAddress : Text;
    #AlreadyProcessing;
    #AmountTooLow : Nat64;
    #InsufficientFunds : { balance : Nat64 };
    #InsufficientAllowance : { allowance : Nat64 };
    #TemporarilyUnavailable : Text;
    #GenericError : { error_message : Text; error_code : Nat64 };
  };

  type ReimbursementReason = {
    #CallFailed;
    #TaintedDestination : {
      kyt_fee : Nat64;
      kyt_provider : Principal;
    };
  };

  public type RetrieveBtcStatusV2 = {
    #Unknown;
    #Pending;
    #Signing;
    #Sending : { txid : Blob };
    #Submitted : { txid : Blob };
    #AmountTooLow;
    #Confirmed : { txid : Blob };
    #Reimbursed : {
      account : { owner : Principal; subaccount : ?Blob };
      mint_block_index : Nat64;
      amount : Nat64;
      reason : ReimbursementReason;
    };
    #WillReimburse : {
      account : { owner : Principal; subaccount : ?Blob };
      amount : Nat64;
      reason : ReimbursementReason;
    };
  };

  public type ApproveError = {
    #BadFee : { expected_fee : Nat };
    #InsufficientFunds : { balance : Nat };
    #AllowanceChanged : { current_allowance : Nat };
    #Expired : { ledger_time : Nat64 };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_message : Text; error_code : Nat64 };
  };

  type CkbtcLedger = actor {
    icrc2_approve : shared ({
      from_subaccount : ?Blob;
      spender : { owner : Principal; subaccount : ?Blob };
      amount : Nat;
      expected_allowance : ?Nat;
      expires_at : ?Nat64;
      fee : ?Nat;
      memo : ?Blob;
      created_at_time : ?Nat64;
    }) -> async { #Ok : Nat; #Err : ApproveError };
  };

  type CkbtcMinter = actor {
    update_balance : shared ({ owner : ?Principal; subaccount : ?Blob }) -> async {
      #Ok : [UtxoStatus];
      #Err : UpdateBalanceError;
    };
    estimate_withdrawal_fee : shared query ({ amount : ?Nat64 }) -> async ({
      bitcoin_fee : Nat64;
      minter_fee : Nat64;
    });
    get_deposit_fee : shared query () -> async Nat64;
    retrieve_btc_with_approval : shared ({
      address : Text;
      amount : Nat64;
      from_subaccount : ?Blob;
    }) -> async {
      #Ok : { block_index : Nat64 };
      #Err : RetrieveBtcWithApprovalError;
    };
    retrieve_btc_status_v2 : shared query ({ block_index : Nat64 }) -> async RetrieveBtcStatusV2;
  };

  public type NotifyError = UpdateBalanceError or { #NotMinted };

  public class BtcHandler(
    auctionPrincipal : Principal,
    ckbtcLedgerPrincipal : Principal,
    minter : {
      principal : Principal;
      xPubKey : CkBtcAddress.XPubKey;
    },
  ) {

    let ckbtcLedger : CkbtcLedger = actor (Principal.toText(ckbtcLedgerPrincipal));
    let ckbtcMinter : CkbtcMinter = actor (Principal.toText(minter.principal));

    let btcAddrFunc = CkBtcAddress.Minter(minter.xPubKey).deposit_addr_func(auctionPrincipal);

    public func calculateDepositAddress(p : Principal) : Text = btcAddrFunc(?TokenHandler.toSubaccount(p));

    public func notify(p : Principal) : async* R.Result<(), NotifyError> {
      let resp = await ckbtcMinter.update_balance({
        owner = ?auctionPrincipal;
        subaccount = ?TokenHandler.toSubaccount(p);
      });
      switch (resp) {
        case (#Err err) return #err(err);
        case (#Ok utxos) {
          for (utxo in utxos.vals()) {
            switch (utxo) {
              case (#Minted _) {};
              case (_) return #err(#NotMinted);
            };
          };
        };
      };
      #ok();
    };

    public func withdraw(address : Text, amount : Nat, ledgerFee : Nat) : async* {
      #Ok : { block_index : Nat64 };
      #Err : ApproveError or RetrieveBtcWithApprovalError;
    } {
      if (amount < ledgerFee * 2) {
        return #Err(#GenericError({ error_code = 0; error_message = "Amount is too low" }));
      };
      let allowanceAmount = Int.abs(amount - ledgerFee); // take allowance creation fee into account
      let approveRes = await ckbtcLedger.icrc2_approve({
        from_subaccount = null;
        amount = allowanceAmount;
        spender = { owner = minter.principal; subaccount = null };
        fee = ?ledgerFee;
        expected_allowance = null;
        created_at_time = null;
        expires_at = null;
        memo = null;
      });
      switch (approveRes) {
        case (#Err err) #Err(err);
        case (#Ok _) {
          await ckbtcMinter.retrieve_btc_with_approval({
            address;
            amount = Nat64.fromNat(allowanceAmount - ledgerFee);
            from_subaccount = null;
          });
        };
      };
    };

    public func getWithdrawalStatus(arg : { block_index : Nat64 }) : async* RetrieveBtcStatusV2 {
      await ckbtcMinter.retrieve_btc_status_v2(arg);
    };

  };

};
