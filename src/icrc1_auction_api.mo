import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";
import Text "mo:base/Text";
import Timer "mo:base/Timer";

import AccountManager "mo:mrr/TokenHandler/AccountManager";
import ICRC1 "mo:mrr/TokenHandler/ICRC1";
import PT "mo:promtracker";
import TokenHandler "mo:mrr/TokenHandler";
import Vec "mo:vector";

import HTTP "./http";
import U "./utils";

import Auction "./auction";

// arguments have to be provided on first canister install,
// on upgrade trusted ledger will be ignored
actor class Icrc1AuctionAPI(trustedLedger_ : ?Principal, adminPrincipal_ : ?Principal) = self {

  stable let trustedLedgerPrincipal : Principal = U.requireMsg(trustedLedger_, "Trusted ledger principal not provided");

  stable var stableAdminsMap = RBTree.RBTree<Principal, ()>(Principal.compare).share();
  switch (RBTree.size(stableAdminsMap)) {
    case (0) {
      let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
      adminsMap.put(U.requireMsg(adminPrincipal_, "Admin not provided"), ());
      stableAdminsMap := adminsMap.share();
    };
    case (_) {};
  };
  let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
  adminsMap.unshare(stableAdminsMap);

  stable var assetsData : Vec.Vector<StableAssetInfo> = Vec.new();
  stable var auctionData : Auction.StableData = Auction.defaultStableData();
  stable var metricsData : PT.StableData = null;

  type AssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.TokenHandler;
  };
  type StableAssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.StableData;
  };

  type RegisterAssetError = {
    #AlreadyRegistered : Nat;
  };

  type Order = {
    icrc1Ledger : Principal;
    price : Float;
    volume : Nat;
  };
  func mapOrder(order : Auction.SharedOrder) : Order = {
    icrc1Ledger = Vec.get(assets, order.assetId).ledgerPrincipal;
    price = order.price;
    volume = order.volume;
  };
  func mapOrderOpt(order : ?Auction.SharedOrder) : ?Order = Option.map<Auction.SharedOrder, Order>(order, mapOrder);

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };
  // TODO use resultToUpper after upgrading motoko-base (0.11.2?)
  private func resultToUpper<Ok, Err>(result : R.Result<Ok, Err>) : UpperResult<Ok, Err> {
    switch result {
      case (#ok(ok)) { #Ok(ok) };
      case (#err(err)) { #Err(err) };
    };
  };

  type AssetHistoryItem = (timestamp : Nat64, sessionNumber : Nat, ledgerPrincipal : Principal, volume : Nat, price : Float);
  type OrderHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, ledgerPrincipal : Principal, volume : Nat, price : Float);

  type TokenInfo = {
    min_deposit : Nat;
    min_withdrawal : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };

  type NotifyResult = {
    #Ok : {
      deposit_inc : Nat;
      credit_inc : Nat;
    };
    #Err : {
      #CallLedgerError : Text;
      #NotAvailable : Text;
    };
  };

  type WithdrawResult = {
    #Ok : {
      txid : Nat;
      amount : Nat;
    };
    #Err : {
      #CallLedgerError : Text;
      #InsufficientCredit;
      #AmountBelowMinimum;
    };
  };

  var auction : ?Auction.Auction = null;
  var assets : Vec.Vector<AssetInfo> = Vec.new();

  let metrics = PT.PromTracker("", 65);
  metrics.addSystemValues();

  let JOURNAL_SIZE = 1024;

  // ICRCX API
  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrcX_supported_tokens() : async [Principal] {
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrcX_token_info(token : Principal) : async TokenInfo {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return (assetInfo.handler.fee(#deposit), assetInfo.handler.fee(#withdrawal)) |> {
          min_deposit = _.0 + 1;
          min_withdrawal = _.1 + 1;
          deposit_fee = _.0;
          withdrawal_fee = _.1;
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrcX_credit(token : Principal) : async Int = async switch (getAssetId(token)) {
    case (?aid) U.unwrapUninit(auction).queryCredit(caller, aid);
    case (_) 0;
  };

  public shared query ({ caller }) func icrcX_all_credits() : async [(Principal, Int)] {
    U.unwrapUninit(auction).queryCredits(caller) |> Array.tabulate<(Principal, Nat)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
  };

  public shared query ({ caller }) func icrcX_trackedDeposit(token : Principal) : async {
    #Ok : Nat;
    #Err : { #NotAvailable : Text };
  } {
    (
      switch (getAssetId(token)) {
        case (?aid) aid;
        case (_) return #Err(#NotAvailable("Unknown token"));
      }
    )
    |> Vec.get(assets, _)
    |> _.handler.trackedDeposit(caller)
    |> (
      switch (_) {
        case (?d) #Ok(d);
        case (null) #Err(#NotAvailable("Unknown caller"));
      }
    );
  };

  public shared ({ caller }) func icrcX_notify(args : { token : Principal }) : async NotifyResult {
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) return #Err(#NotAvailable("Unknown token"));
    };
    let assetInfo = Vec.get(assets, assetId);
    let result = try {
      ignore await* assetInfo.handler.fetchFee();
      await* assetInfo.handler.notify(caller);
    } catch (err) {
      return #Err(#CallLedgerError(Error.message(err)));
    };
    switch (result) {
      case (?(delta, usableBalance)) {
        ignore a.setCredit(caller, assetId, Int.abs(usableBalance));
        #Ok({ deposit_inc = delta; credit_inc = delta });
      };
      case (null) {
        #Ok({
          deposit_inc = 0;
          credit_inc = 0;
        });
      };
    };
  };

  public shared ({ caller }) func deposit_from_allowance(args : { account : ICRC1.Account; amount : Nat; token : Principal }) : async UpperResult<AccountManager.DepositFromAllowanceResult, AccountManager.DepositFromAllowanceError> {
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) throw Error.reject("Unknown token");
    };
    let assetInfo = Vec.get(assets, assetId);
    let res = await* assetInfo.handler.depositFromAllowance(args.account, args.amount);
    switch (res) {
      case (#ok(credited)) {
        ignore a.setCredit(caller, assetId, Int.abs(assetInfo.handler.userCredit(caller)));
        #Ok(credited);
      };
      case (#err x) #Err(x);
    };
  };

  public shared ({ caller }) func icrcX_withdraw(args : { to_subaccount : ?Blob; amount : Nat; token : Principal }) : async WithdrawResult {
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let handler = Vec.get(assets, assetId).handler;
    let rollbackCredit = switch (U.unwrapUninit(auction).deductCredit(caller, assetId, args.amount)) {
      case (#err err) return #Err(#InsufficientCredit);
      case (#ok(_, r)) r;
    };
    let res = await* handler.withdrawFromCredit(caller, { owner = caller; subaccount = args.to_subaccount }, args.amount);
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        rollbackCredit();
        switch (err) {
          case (#TooLowQuantity) #Err(#AmountBelowMinimum);
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError("Call error"));
          case (_) #Err(#CallLedgerError("Try later"));
        };
      };
    };
  };

  // Auction API
  public shared func init() : async () {
    assert Option.isNull(auction);
    assets := Vec.map<StableAssetInfo, AssetInfo>(
      assetsData,
      func(x) {
        let r = (actor (Principal.toText(x.ledgerPrincipal)) : ICRC1.ICRC1Ledger)
        |> {
          balance_of = _.icrc1_balance_of;
          fee = _.icrc1_fee;
          transfer = _.icrc1_transfer;
          transfer_from = _.icrc2_transfer_from;
        }
        |> {
          ledgerPrincipal = x.ledgerPrincipal;
          minAskVolume = x.minAskVolume;
          handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0, true);
        };
        r.handler.unshare(x.handler);
        r;
      },
    );
    let a = Auction.Auction<system>(
      0,
      metrics,
      {
        minAskVolume = func(assetId, _) = Vec.get(assets, assetId).minAskVolume;
      },
      {
        preAuction = null;
        postAuction = null;
      },
    );
    a.unshare(auctionData);
    auction := ?a;
    if (Vec.size(assets) == 0) {
      ignore U.requireOk(registerAsset_(trustedLedgerPrincipal, 0));
    };
    metrics.unshare(metricsData);
  };

  // A timer for consolidating backlog subaccounts
  ignore Timer.recurringTimer<system>(
    #seconds 60,
    func() : async () {
      for (asset in Vec.vals(assets)) {
        await* asset.handler.trigger(1);
      };
    },
  );

  public shared query func getTrustedLedger() : async Principal = async trustedLedgerPrincipal;
  public shared query func sessionRemainingTime() : async Nat = async U.unwrapUninit(auction).remainingTime();
  public shared query func sessionsCounter() : async Nat = async U.unwrapUninit(auction).sessionsCounter;

  private func getIcrc1Ledger(assetId : Nat) : Principal = Vec.get(assets, assetId).ledgerPrincipal;
  private func getAssetId(icrc1Ledger : Principal) : ?Nat {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, icrc1Ledger)) {
        return ?i;
      };
    };
    return null;
  };

  public shared query ({ caller }) func queryBid(ledger : Principal) : async ?Order = async switch (getAssetId(ledger)) {
    case (?aid) U.unwrapUninit(auction).queryBid(caller, aid) |> mapOrderOpt(_);
    case (_) null;
  };
  public shared query ({ caller }) func queryBids() : async [Order] = async U.unwrapUninit(auction).queryBids(caller)
  |> Array.tabulate<Order>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryAsk(ledger : Principal) : async ?Order = async switch (getAssetId(ledger)) {
    case (?aid) U.unwrapUninit(auction).queryAsk(caller, aid) |> mapOrderOpt(_);
    case (_) null;
  };
  public shared query ({ caller }) func queryAsks() : async [Order] = async U.unwrapUninit(auction).queryAsks(caller)
  |> Array.tabulate<Order>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryHistory(limit : Nat, skip : Nat) : async [OrderHistoryItem] {
    U.unwrapUninit(auction).queryHistory(caller, limit, skip) |> Array.tabulate<OrderHistoryItem>(
      _.size(),
      func(i) = (
        _ [i].0,
        _ [i].1,
        _ [i].2,
        Vec.get(assets, _ [i].3).ledgerPrincipal,
        _ [i].4,
        _ [i].5,
      ),
    );
  };
  public shared query func queryTokenHistory(limit : Nat, skip : Nat) : async [AssetHistoryItem] {
    U.unwrapUninit(auction).queryAssetHistory(limit, skip) |> Array.tabulate<AssetHistoryItem>(
      _.size(),
      func(i) = (
        _ [i].0,
        _ [i].1,
        Vec.get(assets, _ [i].2).ledgerPrincipal,
        _ [i].3,
        _ [i].4,
      ),
    );
  };

  public shared ({ caller }) func placeBid(ledger : Principal, volume : Nat, price : Float) : async UpperResult<(), Auction.PlaceOrderError> {
    switch (getAssetId(ledger)) {
      case (?aid) U.unwrapUninit(auction).placeBid(caller, aid, volume, price) |> resultToUpper(_);
      case (_) #Err(#UnknownAsset);
    };
  };

  public shared ({ caller }) func placeAsk(ledger : Principal, volume : Nat, price : Float) : async UpperResult<(), Auction.PlaceOrderError> {
    switch (getAssetId(ledger)) {
      case (?aid) U.unwrapUninit(auction).placeAsk(caller, aid, volume, price) |> resultToUpper(_);
      case (_) #Err(#UnknownAsset);
    };
  };

  public shared ({ caller }) func cancelBid(ledger : Principal) : async UpperResult<Bool, Auction.OrderError> {
    switch (getAssetId(ledger)) {
      case (?aid) U.unwrapUninit(auction).cancelBid(caller, aid) |> resultToUpper(_);
      case (_) #Err(#UnknownAsset);
    };
  };

  public shared ({ caller }) func cancelAsk(ledger : Principal) : async UpperResult<Bool, Auction.OrderError> {
    switch (getAssetId(ledger)) {
      case (?aid) U.unwrapUninit(auction).cancelAsk(caller, aid) |> resultToUpper(_);
      case (_) #Err(#UnknownAsset);
    };
  };

  public query func listAdmins() : async [Principal] = async adminsMap.entries()
  |> Iter.map<(Principal, ()), Principal>(_, func((p, _)) = p)
  |> Iter.toArray(_);

  private func assertAdminAccess(principal : Principal) : async* () {
    if (adminsMap.get(principal) == null) {
      throw Error.reject("No Access for this principal " # Principal.toText(principal));
    };
  };

  public shared ({ caller }) func addAdmin(principal : Principal) : async () {
    await* assertAdminAccess(caller);
    adminsMap.put(principal, ());
  };

  public shared ({ caller }) func removeAdmin(principal : Principal) : async () {
    if (Principal.equal(principal, caller)) {
      throw Error.reject("Cannot remove yourself from admins");
    };
    await* assertAdminAccess(caller);
    adminsMap.delete(principal);
  };

  private func registerAsset_(ledger : Principal, minAskVolume : Nat) : R.Result<Nat, RegisterAssetError> {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(ledger, assetInfo.ledgerPrincipal)) return #err(#AlreadyRegistered(i));
    };
    let id = Vec.size(assets);
    assert id == Vec.size(U.unwrapUninit(auction).assets);
    (actor (Principal.toText(ledger)) : ICRC1.ICRC1Ledger)
    |> {
      balance_of = _.icrc1_balance_of;
      fee = _.icrc1_fee;
      transfer = _.icrc1_transfer;
      transfer_from = _.icrc2_transfer_from;
    }
    |> {
      ledgerPrincipal = ledger;
      minAskVolume = minAskVolume;
      handler = TokenHandler.TokenHandler(_, Principal.fromActor(self), JOURNAL_SIZE, 0, true);
    }
    |> Vec.add<AssetInfo>(assets, _);
    U.unwrapUninit(auction).registerAssets(1);
    #ok(id);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* assertAdminAccess(caller);
    // validate ledger
    let canister = actor (Principal.toText(ledger)) : (actor { icrc1_metadata : () -> async [Any] });
    try {
      ignore await canister.icrc1_metadata();
    } catch (err) {
      throw err;
    };
    registerAsset_(ledger, minAskVolume) |> resultToUpper(_);
  };

  public shared query func debugLastBidProcessingInstructions() : async Nat64 = async U.unwrapUninit(auction).lastBidProcessingInstructions;

  public shared func runAuctionImmediately() : async () {
    await U.unwrapUninit(auction).onTimer();
  };

  public query func http_request(req : HTTP.HttpRequest) : async HTTP.HttpResponse {
    let ?path = Text.split(req.url, #char '?').next() else return HTTP.render400();
    switch (req.method, path, auction) {
      case ("GET", "/metrics", ?_) metrics.renderExposition("canister=\"" # PT.shortName(self) # "\"") |> HTTP.renderPlainText(_);
      case (_) HTTP.render400();
    };
  };

  system func preupgrade() {
    switch (auction) {
      case (?a) {
        assetsData := Vec.map<AssetInfo, StableAssetInfo>(
          assets,
          func(x) = {
            ledgerPrincipal = x.ledgerPrincipal;
            minAskVolume = x.minAskVolume;
            handler = x.handler.share();
          },
        );
        auctionData := a.share();
        metricsData := metrics.share();
      };
      case (null) {};
    };
    stableAdminsMap := adminsMap.share();
  };

};
