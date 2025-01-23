import Principal "mo:base/Principal";
import R "mo:base/Result";
import TokenHandler "mo:token_handler_legacy";

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

  type CkbtcMinter = actor {
    get_btc_address : shared ({ owner : ?Principal; subaccount : ?Blob }) -> async Text;
    update_balance : shared ({ owner : ?Principal; subaccount : ?Blob }) -> async {
      #Ok : [UtxoStatus];
      #Err : UpdateBalanceError;
    };
  };

  public type NotifyError = UpdateBalanceError or { #NotMinted };

  public class BtcHandler(auctionPrincipal : Principal, ckbtcMinterPrincipal : Principal) {

    let ckbtcMinter : CkbtcMinter = actor (Principal.toText(ckbtcMinterPrincipal));

    public func getDepositAddress(p : Principal) : async* Text {
      await ckbtcMinter.get_btc_address({
        owner = ?auctionPrincipal;
        subaccount = ?TokenHandler.toSubaccount(p);
      });
    };

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
  };

};
