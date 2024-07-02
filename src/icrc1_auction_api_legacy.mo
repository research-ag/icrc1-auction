import Array "mo:base/Array";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";
import Text "mo:base/Text";
import Timer "mo:base/Timer";

import Auction "mo:auction";
import ICRC1 "mo:token_handler/ICRC1";
import PT "mo:promtracker";
import TokenHandler "mo:token_handler";
import Vec "mo:vector";

import HTTP "./http";
import U "./utils";

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
  stable var auctionDataV1 : Auction.StableDataV1 = Auction.defaultStableDataV1();

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
  func mapOrder(order : (Auction.OrderId, Auction.SharedOrder)) : (Auction.OrderId, Order) = (
    order.0,
    {
      icrc1Ledger = Vec.get(assets, order.1.assetId).ledgerPrincipal;
      price = order.1.price;
      volume = order.1.volume;
    },
  );

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };
  // TODO use resultToUpper after upgrading motoko-base (0.11.2?)
  private func resultToUpper<Ok, Err>(result : R.Result<Ok, Err>) : UpperResult<Ok, Err> {
    switch result {
      case (#ok(ok)) { #Ok(ok) };
      case (#err(err)) { #Err(err) };
    };
  };

  type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, ledgerPrincipal : Principal, volume : Nat, price : Float);
  type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, ledgerPrincipal : Principal, volume : Nat, price : Float);

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
      case (?_) {
        let userCredit = assetInfo.handler.userCredit(caller);
        if (userCredit > 0) {
          let inc = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(caller, inc);
          ignore a.appendCredit(caller, assetId, inc);
          #Ok({ deposit_inc = inc; credit_inc = inc });
        } else {
          #Err(#NotAvailable("Deposit was not detected"));
        };
      };
      case (null) #Err(#NotAvailable("Deposit was not detected"));
    };
  };

  public shared ({ caller }) func icrcX_deposit(args : { token : Principal; amount : Nat; subaccount : ?Blob }) : async UpperResult<{ txid : Nat; credit_inc : Nat }, { #AmountBelowMinimum; #CallLedgerError : Text; #TransferError : Text }> {
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) throw Error.reject("Unknown token");
    };
    let assetInfo = Vec.get(assets, assetId);
    let res = await* assetInfo.handler.depositFromAllowance(caller, { owner = caller; subaccount = args.subaccount }, args.amount);
    switch (res) {
      case (#ok(credited, txid)) {
        assert assetInfo.handler.debitUser(caller, credited);
        ignore a.appendCredit(caller, assetId, credited);
        #Ok({
          credit_inc = credited;
          txid = txid;
        });
      };
      case (#err x) #Err(
        switch (x) {
          case (#TooLowQuantity) #AmountBelowMinimum;
          case (#CallIcrc1LedgerError) #CallLedgerError("Call failed");
          case (#InsufficientAllowance _) #TransferError("Insufficient allowance");
          case (#InsufficientFunds _) #TransferError("Insufficient funds");
          case (_) #TransferError("Unexpected error");
        }
      );
    };
  };

  public shared ({ caller }) func icrcX_withdraw(args : { to_subaccount : ?Blob; amount : Nat; token : Principal }) : async WithdrawResult {
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let handler = Vec.get(assets, assetId).handler;
    let rollbackCredit = switch (U.unwrapUninit(auction).deductCredit(caller, assetId, args.amount)) {
      case (#err err) return #Err(#InsufficientCredit);
      case (#ok(_, r)) r;
    };
    let res = await* handler.withdrawFromPool({ owner = caller; subaccount = args.to_subaccount }, args.amount);
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
          handler = TokenHandler.TokenHandler({
            ledgerApi = _;
            ownPrincipal = Principal.fromActor(self);
            initialFee = 0;
            triggerOnNotifications = true;
            log = func(p : Principal, logEvent : TokenHandler.LogEvent) = ();
          });
        };
        r.handler.unshare(x.handler);
        r;
      },
    );
    let a = Auction.Auction(
      0,
      {
        minimumOrder = 5_000;
        minAskVolume = func(assetId, _) = Vec.get(assets, assetId).minAskVolume;
        performanceCounter = Prim.performanceCounter;
      },
    );
    a.unshare(auctionDataV1);
    auction := ?a;

    ignore metrics.addPullValue("sessions_counter", "", func() = a.sessionsCounter);
    ignore metrics.addPullValue("assets_amount", "", func() = Vec.size(a.assets));
    ignore metrics.addPullValue("users_amount", "", func() = a.stats.usersAmount);
    ignore metrics.addPullValue("accounts_amount", "", func() = a.stats.accountsAmount);

    if (Vec.size(assets) == 0) {
      ignore U.requireOk(registerAsset_(trustedLedgerPrincipal, 0));
    } else {
      for (assetId in Vec.keys(a.assets)) {
        registerAssetMetrics_(assetId);
      };
    };
  };

  public shared query func getTrustedLedger() : async Principal = async trustedLedgerPrincipal;
  public shared query func sessionRemainingTime() : async Nat = async remainingTime();
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

  public shared query ({ caller }) func queryTokenBids(ledger : Principal) : async [(Auction.OrderId, Order)] = async switch (getAssetId(ledger)) {
    case (?aid) {
      U.unwrapUninit(auction).queryAssetBids(caller, aid)
      |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
    };
    case (_) [];
  };

  // TODO replace function

  public shared query ({ caller }) func queryBids() : async [(Auction.OrderId, Order)] = async U.unwrapUninit(auction).queryBids(caller)
  |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryTokenAsks(ledger : Principal) : async [(Auction.OrderId, Order)] = async switch (getAssetId(ledger)) {
    case (?aid) {
      U.unwrapUninit(auction).queryAssetAsks(caller, aid)
      |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
    };
    case (_) [];
  };
  public shared query ({ caller }) func queryAsks() : async [(Auction.OrderId, Order)] = async U.unwrapUninit(auction).queryAsks(caller)
  |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryTransactionHistory(token : ?Principal, limit : Nat, skip : Nat) : async [TransactionHistoryItem] {
    Option.map<Principal, ?Auction.AssetId>(token, getAssetId)
    |> Option.flatten(_)
    |> U.unwrapUninit(auction).queryTransactionHistory(caller, _, limit, skip)
    |> Array.tabulate<TransactionHistoryItem>(_.size(), func(i) = (_ [i].0, _ [i].1, _ [i].2, Vec.get(assets, _ [i].3).ledgerPrincipal, _ [i].4, _ [i].5));
  };

  public shared query func queryPriceHistory(token : ?Principal, limit : Nat, skip : Nat) : async [PriceHistoryItem] {
    Option.map<Principal, ?Auction.AssetId>(token, getAssetId)
    |> Option.flatten(_)
    |> U.unwrapUninit(auction).queryPriceHistory(_, limit, skip)
    |> Array.tabulate<PriceHistoryItem>(_.size(), func(i) = (_ [i].0, _ [i].1, Vec.get(assets, _ [i].2).ledgerPrincipal, _ [i].3, _ [i].4));
  };

  public shared ({ caller }) func placeBids(arg : [(ledger : Principal, volume : Nat, price : Float)]) : async [UpperResult<Auction.OrderId, Auction.PlaceOrderError>] {
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeBid(caller, aid, arg[i].1, arg[i].2) |> resultToUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    U.unwrapUninit(auction).replaceBid(caller, orderId, volume : Nat, price : Float) |> resultToUpper(_);
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId]) : async [UpperResult<Bool, Auction.CancelOrderError>] {
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<Bool, Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelBid(caller, orderIds[i]) |> resultToUpper(_),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, volume : Nat, price : Float)]) : async [UpperResult<Auction.OrderId, Auction.PlaceOrderError>] {
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeAsk(caller, aid, arg[i].1, arg[i].2) |> resultToUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    U.unwrapUninit(auction).replaceAsk(caller, orderId, volume : Nat, price : Float) |> resultToUpper(_);
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId]) : async [UpperResult<Bool, Auction.CancelOrderError>] {
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<Bool, Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelAsk(caller, orderIds[i]) |> resultToUpper(_),
    );
  };

  public query func queryTokenHandlerState(ledger : Principal) : async {
    balance : {
      deposited : Nat;
      underway : Nat;
      queued : Nat;
      consolidated : Nat;
    };
    flow : {
      consolidated : Nat;
      withdrawn : Nat;
    };
    credit : {
      total : Int;
      pool : Int;
    };
    users : {
      queued : Nat;
    };
  } {
    switch (getAssetId(ledger)) {
      case (?aid) Vec.get(assets, aid) |> _.handler.state();
      case (_) throw Error.reject("Unknown asset");
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

  private func registerAssetMetrics_(assetId : Auction.AssetId) {
    let stats = Vec.get(U.unwrapUninit(auction).stats.assets, assetId);
    ignore metrics.addPullValue("asks_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.asksAmount);
    ignore metrics.addPullValue("asks_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.totalAskVolume);
    ignore metrics.addPullValue("bids_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.bidsAmount);
    ignore metrics.addPullValue("bids_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.totalBidVolume);
    ignore metrics.addPullValue("processing_instructions", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.lastProcessingInstructions);
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
      handler = TokenHandler.TokenHandler({
        ledgerApi = _;
        ownPrincipal = Principal.fromActor(self);
        initialFee = 0;
        triggerOnNotifications = true;
        log = func(p : Principal, logEvent : TokenHandler.LogEvent) = ();
      });
    }
    |> Vec.add<AssetInfo>(assets, _);
    U.unwrapUninit(auction).registerAssets(1);
    registerAssetMetrics_(id);
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

  public shared query func debugLastBidProcessingInstructions() : async Nat64 = async lastBidProcessingInstructions;

  public shared func runAuctionImmediately() : async () {
    await runAuction();
  };

  // Auction processing functionality

  var nextAssetIdToProcess : Nat = 0;
  let trustedAssetId : Auction.AssetId = 0;
  // total instructions sent on last auction processing routine. Accumulated in case processing was splitted to few heartbeat calls
  var lastBidProcessingInstructions : Nat64 = 0;
  // amount of chunks, used for processing all assets
  var lastBidProcessingChunks : Nat8 = 0;
  // when spent instructions on bids processing exceeds this value, we stop iterating over assets and commit processed ones.
  // Canister will continue processing them on next heartbeat
  let BID_PROCESSING_INSTRUCTIONS_THRESHOLD : Nat64 = 1_000_000_000;

  // loops over asset ids, beginning from provided asset id and processes them one by one.
  // stops if we exceed instructions threshold and returns #nextIndex in this case
  private func processAssetsChunk(auction : Auction.Auction, startIndex : Nat) : {
    #done;
    #nextIndex : Nat;
  } {
    let startInstructions = Prim.performanceCounter(0);
    let newSwapRates : Vec.Vector<(Auction.AssetId, Float)> = Vec.new();
    Vec.add(newSwapRates, (trustedAssetId, 1.0));
    var nextAssetId = 0;
    label l for (assetId in Iter.range(startIndex, Vec.size(assets) - 1)) {
      nextAssetId := assetId + 1;
      auction.processAsset(assetId);
      if (Prim.performanceCounter(0) > startInstructions + BID_PROCESSING_INSTRUCTIONS_THRESHOLD) break l;
    };
    if (startIndex == 0) {
      lastBidProcessingInstructions := Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks := 1;
    } else {
      lastBidProcessingInstructions += Prim.performanceCounter(0) - startInstructions;
      lastBidProcessingChunks += 1;
    };
    if (nextAssetId == Vec.size(assets)) {
      #done();
    } else {
      #nextIndex(nextAssetId);
    };
  };

  private func runAuction() : async () {
    let a = U.requireMsg(auction, "Not initialized");
    switch (processAssetsChunk(a, nextAssetIdToProcess)) {
      case (#done) {
        a.sessionsCounter += 1;
        nextAssetIdToProcess := 0;
      };
      case (#nextIndex next) {
        if (next == nextAssetIdToProcess) {
          Prim.trap("Can never happen: not a single asset processed");
        };
        nextAssetIdToProcess := next;
        ignore Timer.setTimer<system>(#seconds(1), runAuction);
      };
    };
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
        auctionDataV1 := a.share();
      };
      case (null) {};
    };
    stableAdminsMap := adminsMap.share();
  };

  // A timer for consolidating backlog subaccounts
  ignore Timer.recurringTimer<system>(
    #seconds 60,
    func() : async () {
      for (asset in Vec.vals(assets)) {
        await* asset.handler.trigger(10);
      };
    },
  );

  let AUCTION_INTERVAL_SECONDS : Nat64 = 86_400; // a day
  private func remainingTime() : Nat = Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000 + 43_200) % AUCTION_INTERVAL_SECONDS);

  // run daily at 12:00 p.m. UTC
  ignore (
    func() : async () {
      ignore Timer.recurringTimer<system>(
        #seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS)),
        func() : async () = async switch (auction) {
          case (?a) await runAuction();
          case (null) {};
        },
      );
      switch (auction) {
        case (?a) await runAuction();
        case (null) {};
      };
    }
  ) |> Timer.setTimer<system>(#seconds(remainingTime()), _);

};
