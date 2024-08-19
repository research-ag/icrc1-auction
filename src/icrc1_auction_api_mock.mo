import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Error "mo:base/Error";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";
import Text "mo:base/Text";
import Timer "mo:base/Timer";

import Auction "./auction/src";
import PT "mo:promtracker";
import TokenHandler "mo:token_handler";
import Vec "mo:vector";

import HTTP "./http";
import U "./utils";

actor class Icrc1AuctionAPI(adminPrincipal_ : ?Principal) = self {

  func principalFromNat(n : Nat) : Principal {
    let blobLength = 16;
    Principal.fromBlob(
      Blob.fromArray(
        Array.tabulate<Nat8>(
          blobLength,
          func(i : Nat) : Nat8 {
            assert (i < blobLength);
            let shift : Nat = 8 * (blobLength - 1 - i);
            Nat8.fromIntWrap(n / 2 ** shift);
          },
        )
      )
    );
  };

  stable let trustedLedgerPrincipal : Principal = principalFromNat(0);
  stable let quoteLedgerPrincipal : Principal = trustedLedgerPrincipal;

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
  stable var auctionDataV2 : Auction.StableDataV2 = Auction.migrateStableDataV2(auctionDataV1);

  type AssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
  };
  type StableAssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
  };

  type RegisterAssetError = {
    #AlreadyRegistered : Nat;
  };

  type Order = {
    icrc1Ledger : Principal;
    price : Float;
    volume : Nat;
  };
  func mapOrder(order : (Auction.OrderId, Auction.Order)) : (Auction.OrderId, Order) = (
    order.0,
    {
      icrc1Ledger = Vec.get(assets, order.1.assetId).ledgerPrincipal;
      price = order.1.price;
      volume = order.1.volume;
    },
  );

  type UpperResult<Ok, Err> = { #Ok : Ok; #Err : Err };

  type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, ledgerPrincipal : Principal, volume : Nat, price : Float);
  type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, ledgerPrincipal : Principal, volume : Nat, price : Float);

  type TokenInfo = {
    allowance_fee : Nat;
    deposit_fee : Nat;
    withdrawal_fee : Nat;
  };

  type NotifyResult = {
    #Ok : {
      deposit_inc : Nat;
      credit_inc : Nat;
      credit : Int;
    };
    #Err : {
      #CallLedgerError : { message : Text };
      #NotAvailable : { message : Text };
    };
  };

  type DepositResult = UpperResult<{ txid : Nat; credit_inc : Nat; credit : Int }, { #AmountBelowMinimum : {}; #CallLedgerError : { message : Text }; #TransferError : { message : Text }; #BadFee : { expected_fee : Nat } }>;

  type WithdrawResult = {
    #Ok : {
      txid : Nat;
      amount : Nat;
    };
    #Err : {
      #BadFee : { expected_fee : Nat };
      #CallLedgerError : { message : Text };
      #InsufficientCredit : {};
      #AmountBelowMinimum : {};
    };
  };

  var auction : ?Auction.Auction = null;
  var assets : Vec.Vector<AssetInfo> = Vec.new();

  let metrics = PT.PromTracker("", 65);
  metrics.addSystemValues();

  // ICRC84 API
  public shared query func principalToSubaccount(p : Principal) : async ?Blob = async ?TokenHandler.toSubaccount(p);

  public shared query func icrc84_supported_tokens() : async [Principal] {
    Array.tabulate<Principal>(
      Vec.size(assets),
      func(i) = Vec.get(assets, i).ledgerPrincipal,
    );
  };

  public shared query func icrc84_token_info(token : Principal) : async TokenInfo {
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(assetInfo.ledgerPrincipal, token)) {
        return {
          deposit_fee = 0;
          withdrawal_fee = 0;
          allowance_fee = 0;
        };
      };
    };
    throw Error.reject("Unknown token");
  };

  public shared query ({ caller }) func icrc84_credit(token : Principal) : async Int = async switch (getAssetId(token)) {
    case (?aid) U.unwrapUninit(auction).getCredit(caller, aid).available;
    case (_) 0;
  };

  public shared query ({ caller }) func icrc84_all_credits() : async [(Principal, Int)] {
    U.unwrapUninit(auction).getCredits(caller) |> Array.tabulate<(Principal, Int)>(
      _.size(),
      func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1.available),
    );
  };

  public shared query func icrc84_trackedDeposit(token : Principal) : async {
    #Ok : Nat;
    #Err : { #NotAvailable : { message : Text } };
  } {
    (
      switch (getAssetId(token)) {
        case (?aid) aid;
        case (_) return #Err(#NotAvailable({ message = "Unknown token" }));
      }
    )
    |> Vec.get(assets, _)
    |> #Ok(0);
  };

  public shared ({ caller }) func icrc84_notify(args : { token : Principal }) : async NotifyResult {
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) return #Err(#NotAvailable({ message = "Unknown token" }));
    };
    let assetInfo = Vec.get(assets, assetId);
    ignore a.appendCredit(caller, assetId, 1_000_000);
    #Ok({
      deposit_inc = 1_000_000;
      credit_inc = 1_000_000;
      credit = a.getCredit(caller, assetId).available;
    });
  };

  public shared ({ caller }) func icrc84_deposit(args : { token : Principal; amount : Nat; from : { owner : Principal; subaccount : ?Blob }; expected_fee : ?Nat }) : async DepositResult {
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) throw Error.reject("Unknown token");
    };
    let assetInfo = Vec.get(assets, assetId);
    ignore a.appendCredit(caller, assetId, args.amount);
    #Ok({
      credit_inc = args.amount;
      txid = 0;
      credit = a.getCredit(caller, assetId).available;
    });
  };

  public shared func icrc84_withdraw(args : { to_subaccount : ?Blob; amount : Nat; token : Principal; expected_fee : ?Nat }) : async WithdrawResult {
    let ?_ = getAssetId(args.token) else throw Error.reject("Unknown token");
    #Err(#CallLedgerError({ message = "Try later" }));
  };

  // Auction API
  public shared func init() : async () {
    assert Option.isNull(auction);
    assets := Vec.map<StableAssetInfo, AssetInfo>(
      assetsData,
      func(x) {
        {
          ledgerPrincipal = x.ledgerPrincipal;
          minAskVolume = x.minAskVolume;
        };
      },
    );
    let a = Auction.Auction(
      0,
      {
        volumeStepLog10 = 3; // minimum quote volume step 1_000
        minVolumeSteps = 5; // minimum quote volume is 5_000
        priceMaxDigits = 5;
        minAskVolume = func(assetId, _) = Vec.get(assets, assetId).minAskVolume;
        performanceCounter = Prim.performanceCounter;
      },
    );
    a.unshare(auctionDataV2);
    auction := ?a;

    ignore metrics.addPullValue("sessions_counter", "", func() = a.sessionsCounter);
    ignore metrics.addPullValue("assets_amount", "", func() = a.assets.nAssets());
    ignore metrics.addPullValue("users_amount", "", func() = a.users.nUsers());
    ignore metrics.addPullValue("users_with_credits_amount", "", func() = a.users.nUsersWithCredits());
    ignore metrics.addPullValue("accounts_amount", "", func() = a.credits.nAccounts());

    if (Vec.size(assets) == 0) {
      ignore U.requireOk(registerAsset_(quoteLedgerPrincipal, 0));
    } else {
      for (assetId in Iter.range(0, a.assets.nAssets() - 1)) {
        registerAssetMetrics_(assetId);
      };
    };
  };

  public shared query func getQuoteLedger() : async Principal = async quoteLedgerPrincipal;
  public shared query func sessionRemainingTime() : async Nat = async remainingTime();
  public shared query func sessionsCounter() : async Nat = async U.unwrapUninit(auction).sessionsCounter;

  public shared query func settings() : async {
    orderQuoteVolumeMinimum : Nat;
    orderQuoteVolumeStep : Nat;
    orderPriceDigitsLimit : Nat;
  } {
    {
      orderQuoteVolumeMinimum = U.unwrapUninit(auction).orders.minQuoteVolume;
      orderQuoteVolumeStep = U.unwrapUninit(auction).orders.quoteVolumeStep;
      orderPriceDigitsLimit = U.unwrapUninit(auction).orders.priceMaxDigits;
    };
  };

  public shared query func indicativeStats(icrc1Ledger : Principal) : async Auction.IndicativeStats {
    if (icrc1Ledger == quoteLedgerPrincipal) throw Error.reject("Unknown asset");
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    U.unwrapUninit(auction).indicativeAssetStats(assetId);
  };

  public shared query ({ caller }) func queryCredits() : async [(Principal, Auction.CreditInfo)] {
    U.unwrapUninit(auction).getCredits(caller) |> Array.tabulate<(Principal, Auction.CreditInfo)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
  };

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
      U.unwrapUninit(auction).getOrders(caller, #bid, ?aid)
      |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
    };
    case (_) [];
  };

  public shared query ({ caller }) func queryBids() : async [(Auction.OrderId, Order)] = async U.unwrapUninit(auction).getOrders(caller, #bid, null)
  |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryTokenAsks(ledger : Principal) : async [(Auction.OrderId, Order)] = async switch (getAssetId(ledger)) {
    case (?aid) {
      U.unwrapUninit(auction).getOrders(caller, #ask, ?aid)
      |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
    };
    case (_) [];
  };
  public shared query ({ caller }) func queryAsks() : async [(Auction.OrderId, Order)] = async U.unwrapUninit(auction).getOrders(caller, #ask, null)
  |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));

  public shared query ({ caller }) func queryTransactionHistory(token : ?Principal, limit : Nat, skip : Nat) : async [TransactionHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    U.unwrapUninit(auction).getTransactionHistory(caller, assetId)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, Vec.get(assets, x.3).ledgerPrincipal, x.4, x.5));
  };

  public shared query func queryPriceHistory(token : ?Principal, limit : Nat, skip : Nat) : async [PriceHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    U.unwrapUninit(auction).getPriceHistory(assetId)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3, x.4));
  };

  type ManageOrdersError = {
    #UnknownPrincipal;
    #cancellation : { index : Nat; error : { #UnknownAsset; #UnknownOrder } };
    #placement : {
      index : Nat;
      error : {
        #ConflictingOrder : ({ #ask; #bid }, ?Auction.OrderId);
        #NoCredit;
        #TooLowOrder;
        #UnknownAsset;
        #PriceDigitsOverflow : { maxDigits : Nat };
        #VolumeStepViolated : { baseVolumeStep : Nat };
      };
    };
  };

  public shared ({ caller }) func manageOrders(
    cancellations : ?{
      #all : ?[Principal];
      #orders : [{ #ask : Auction.OrderId; #bid : Auction.OrderId }];
    },
    placements : [{
      #ask : (token : Principal, volume : Nat, price : Float);
      #bid : (token : Principal, volume : Nat, price : Float);
    }],
  ) : async UpperResult<[Auction.OrderId], ManageOrdersError> {
    let cancellationArg : ?Auction.CancellationAction = switch (cancellations) {
      case (null) null;
      case (? #orders x) ? #orders(x);
      case (? #all null) ? #all(null);
      case (? #all(?tokens)) {
        let aids = Array.init<Nat>(tokens.size(), 0);
        for (i in tokens.keys()) {
          let ?aid = getAssetId(tokens[i]) else return #Err(#cancellation({ index = i; error = #UnknownAsset }));
          aids[i] := aid;
        };
        ? #all(?Array.freeze(aids));
      };
    };
    let placementArg = Array.init<Auction.PlaceOrderAction>(placements.size(), #ask(0, 0, 0.0));
    for (i in placements.keys()) {
      let placement = placements[i];
      let token = switch (placement) { case (#ask x or #bid x) x.0 };
      let ?aid = getAssetId(token) else return #Err(#placement({ index = i; error = #UnknownAsset }));
      placementArg[i] := switch (placement) {
        case (#ask(_, volume, price)) #ask(aid, volume, price);
        case (#bid(_, volume, price)) #bid(aid, volume, price);
      };
    };
    U.unwrapUninit(auction)
    |> _.manageOrders(caller, cancellationArg, Array.freeze(placementArg))
    |> R.toUpper(_);
  };

  public shared ({ caller }) func placeBids(arg : [(ledger : Principal, volume : Nat, price : Float)]) : async [UpperResult<Auction.OrderId, Auction.PlaceOrderError>] {
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeOrder(caller, #bid, aid, arg[i].1, arg[i].2) |> R.toUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    U.unwrapUninit(auction).replaceOrder(caller, #bid, orderId, volume : Nat, price : Float) |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId]) : async [UpperResult<(), Auction.CancelOrderError>] {
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<(), Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelOrder(caller, #bid, orderIds[i]) |> R.toUpper(_),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, volume : Nat, price : Float)]) : async [UpperResult<Auction.OrderId, Auction.PlaceOrderError>] {
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeOrder(caller, #ask, aid, arg[i].1, arg[i].2) |> R.toUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    U.unwrapUninit(auction).replaceOrder(caller, #ask, orderId, volume : Nat, price : Float) |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId]) : async [UpperResult<(), Auction.CancelOrderError>] {
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<(), Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelOrder(caller, #ask, orderIds[i]) |> R.toUpper(_),
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
      case (?_) Prim.trap("Not implemented");
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
    let stats = U.unwrapUninit(auction).assets.getAsset(assetId);
    ignore metrics.addPullValue("asks_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.asks.size);
    ignore metrics.addPullValue("asks_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.asks.totalVolume);
    ignore metrics.addPullValue("bids_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.bids.size);
    ignore metrics.addPullValue("bids_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.bids.totalVolume);
    ignore metrics.addPullValue("processing_instructions", "asset_id=\"" # Nat.toText(assetId) # "\"", func() = stats.lastProcessingInstructions);
  };

  private func registerAsset_(_ : Principal, minAskVolume : Nat) : R.Result<Nat, RegisterAssetError> {
    let id = Vec.size(assets);
    assert id == U.unwrapUninit(auction).assets.nAssets();
    let p = principalFromNat(id);
    {
      ledgerPrincipal = p;
      minAskVolume = minAskVolume;
    }
    |> Vec.add<AssetInfo>(assets, _);
    U.unwrapUninit(auction).registerAssets(1);
    registerAssetMetrics_(id);
    #ok(id);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* assertAdminAccess(caller);
    registerAsset_(ledger, minAskVolume) |> R.toUpper(_);
  };

  public shared query func debugLastBidProcessingInstructions() : async Nat64 = async lastBidProcessingInstructions;

  public shared func runAuctionImmediately() : async () {
    await runAuction();
  };

  // Auction processing functionality

  var nextAssetIdToProcess : Nat = 0;
  let quoteAssetId : Auction.AssetId = 0;
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
    Vec.add(newSwapRates, (quoteAssetId, 1.0));
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
          },
        );
        auctionDataV2 := a.share();
      };
      case (null) {};
    };
    stableAdminsMap := adminsMap.share();
  };

  let AUCTION_INTERVAL_SECONDS : Nat64 = 86_400; // a day
  private func remainingTime() : Nat = Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000 + 43_200) % AUCTION_INTERVAL_SECONDS);

  // run daily at 12:00 p.m. UTC
  ignore (
    func() : async () {
      ignore Timer.recurringTimer<system>(
        #seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS)),
        func() : async () = async switch (auction) {
          case (?_) await runAuction();
          case (null) {};
        },
      );
      switch (auction) {
        case (?_) await runAuction();
        case (null) {};
      };
    }
  ) |> Timer.setTimer<system>(#seconds(remainingTime()), _);

};
