import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Map "mo:core/Map";
import Nat8 "mo:core/Nat8";
import Option "mo:core/Option";
import Order "mo:core/Order";
import Principal "mo:core/Principal";

persistent actor class ICRC1Ledger(symbol_ : ?Text, decimals_ : ?Nat8) = self {
  type Account = {
    var balance : Nat;
  };

  public type Subaccount = Blob;
  public type AccountRefOpt = { owner : Principal; subaccount : ?Subaccount };
  public type AccountRef = { owner : Principal; subaccount : Subaccount };
  public type TransferArgs = {
    from_subaccount : ?Subaccount;
    to : AccountRefOpt;
    amount : Nat;
    fee : ?Nat;
    memo : ?Blob;
    created_at_time : ?Nat64;
  };
  public type TransferError = {
    #BadFee : { expected_fee : Nat };
    #BadBurn : { min_burn_amount : Nat };
    #InsufficientFunds : { balance : Nat };
    #TooOld;
    #CreatedInFuture : { ledger_time : Nat64 };
    #Duplicate : { duplicate_of : Nat };
    #TemporarilyUnavailable;
    #GenericError : { error_code : Nat; message : Text };
  };

  transient let TOKEN_SYMBOL = Option.get<Text>(symbol_, "MOCK");
  transient let TOKEN_DECIMALS = Option.get<Nat8>(decimals_, 2);

  transient let zeroSubaccount = Array.tabulate<Nat8>(32, func(n) = 0).toBlob();
  func deoptRef(r : AccountRefOpt) : AccountRef = ({
    owner = r.owner;
    subaccount = Option.get(r.subaccount, zeroSubaccount);
  });

  func accRefOrder(a : AccountRef, b : AccountRef) : Order.Order = switch (Principal.compare(a.owner, b.owner)) {
    case (#equal) Blob.compare(a.subaccount, b.subaccount);
    case (x) x;
  };
  // Define a map to store accounts
  transient var accounts : Map.Map<AccountRef, Account> = Map.empty();
  transient var fee : Nat = 0;
  transient var txIndex : Nat = 29138;

  private func getBalance(account : AccountRefOpt) : Nat = switch (accounts.get(accRefOrder, deoptRef(account))) {
    case (null) 0;
    case (?acc) acc.balance;
  };

  // =============================================== ICRC1 API ===============================================
  // Define a function to transfer funds between accounts
  public shared ({ caller }) func icrc1_transfer(args : TransferArgs) : async ({
    #Ok : Nat;
    #Err : TransferError;
  }) {
    switch (accounts.get(accRefOrder, { owner = caller; subaccount = Option.get(args.from_subaccount, zeroSubaccount) })) {
      case (null) #Err(#InsufficientFunds({ balance = 0 }));
      case (?fromAcc) {
        if (Option.get(args.fee, fee) != fee) {
          return #Err(#BadFee { expected_fee = fee });
        };
        if (fromAcc.balance < args.amount + fee) {
          return #Err(#InsufficientFunds({ balance = fromAcc.balance }));
        };
        fromAcc.balance -= args.amount + fee;
        switch (accounts.get(accRefOrder, deoptRef(args.to))) {
          case (null) {
            accounts.add(accRefOrder, deoptRef(args.to), { var balance = args.amount });
          };
          case (?toAcc) {
            toAcc.balance += args.amount;
          };
        };
        txIndex += 1;
        #Ok(txIndex);
      };
    };
  };

  public shared query func icrc1_symbol() : async Text = async TOKEN_SYMBOL;

  public shared query func icrc1_decimals() : async Nat8 = async TOKEN_DECIMALS;

  public shared query func icrc1_fee() : async Nat = async fee;

  public shared query func icrc1_metadata() : async [(Text, { #Int : Int; #Nat : Nat; #Blob : Blob; #Text : Text })] = async [
    ("icrc1:decimals", #Nat(Nat8.toNat(TOKEN_DECIMALS))),
    ("icrc1:name", #Text("Mock")),
    ("icrc1:symbol", #Text(TOKEN_SYMBOL)),
    ("icrc1:fee", #Nat(fee)),
  ];

  // Define a function to get the balance of an account
  public shared func icrc1_balance_of(account : AccountRefOpt) : async Nat = async getBalance(account);
  // =============================================== ICRC1 API ===============================================

  // =============================================== CUSTOM API ==============================================
  // Define a function to add some tokens to account for testing
  public shared func issueTokens(account : AccountRefOpt, tokensAmount : Nat) : async () {
    let curBalance = getBalance(account);
    accounts.add(accRefOrder, deoptRef(account), { var balance = curBalance + tokensAmount });
  };
  public shared func updateFee(newFee : Nat) : async () {
    fee := newFee;
  };
  // =============================================== CUSTOM API ==============================================
};
