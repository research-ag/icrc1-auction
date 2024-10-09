import Array "mo:base/Array";
import Error "mo:base/Error";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
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
import ICRC1 "mo:token_handler_legacy/ICRC1";
import PT "mo:promtracker";
import TokenHandler "mo:token_handler_legacy";
import Vec "mo:vector";

import HTTP "./http";
import U "./utils";

// arguments have to be provided on first canister install,
// on upgrade quote ledger will be ignored
actor class Icrc1AuctionAPI(quoteLedger_ : ?Principal, adminPrincipal_ : ?Principal) = self {

  stable let trustedLedgerPrincipal : Principal = U.requireMsg(quoteLedger_, "Quote ledger principal not provided");
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

  stable var assetsDataV2 : Vec.Vector<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : TokenHandler.StableData; decimals : Nat }> = Vec.new();
  stable var assetsDataV3 : Vec.Vector<StableAssetInfo> = Vec.map<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : TokenHandler.StableData; decimals : Nat }, StableAssetInfo>(assetsDataV2, func(ad) = { ad with symbol = "" });

  stable var auctionDataV3 : Auction.StableDataV3 = Auction.defaultStableDataV3();
  stable var auctionDataV4 : Auction.StableDataV4 = Auction.migrateStableDataV4(auctionDataV3);
  stable var auctionDataV5 : Auction.StableDataV5 = Auction.migrateStableDataV5(auctionDataV4);
  stable var auctionDataV6 : Auction.StableDataV6 = Auction.migrateStableDataV6(auctionDataV5);

  stable var ptData : PT.StableData = null;

  stable var tokenHandlersJournal : Vec.Vector<(ledger : Principal, p : Principal, logEvent : TokenHandler.LogEvent)> = Vec.new();

  type AssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.TokenHandler;
    symbol : Text;
    decimals : Nat;
  };
  type StableAssetInfo = {
    ledgerPrincipal : Principal;
    minAskVolume : Nat;
    handler : TokenHandler.StableData;
    symbol : Text;
    decimals : Nat;
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
  type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal; #withdrawalRollback }, ledgerPrincipal : Principal, volume : Nat);
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
  let sessionStartTimeGauge = metrics.addGauge("session_start_time_offset_ms", "", #none, [0, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000], false);

  // call stats
  let notifyCounter = metrics.addCounter("total_calls__icrc84_notify", "", true);
  let depositCounter = metrics.addCounter("total_calls__icrc84_deposit", "", true);
  let withdrawCounter = metrics.addCounter("total_calls__icrc84_withdraw", "", true);
  let manageOrdersCounter = metrics.addCounter("total_calls__manageOrders", "", true);
  let orderPlacementCounter = metrics.addCounter("total_calls__order_placement", "", true);
  let orderReplacementCounter = metrics.addCounter("total_calls__order_replacement", "", true);
  let orderCancellationCounter = metrics.addCounter("total_calls__order_cancellation", "", true);

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
          deposit_fee = assetInfo.handler.fee(#deposit);
          withdrawal_fee = assetInfo.handler.fee(#withdrawal);
          allowance_fee = assetInfo.handler.fee(#allowance);
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

  public shared query ({ caller }) func icrc84_trackedDeposit(token : Principal) : async {
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
    |> _.handler.trackedDeposit(caller)
    |> #Ok(Option.get<Nat>(_, 0));
  };

  public shared ({ caller }) func icrc84_notify(args : { token : Principal }) : async NotifyResult {
    notifyCounter.add(1);
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) return #Err(#NotAvailable({ message = "Unknown token" }));
    };
    let assetInfo = Vec.get(assets, assetId);
    let result = try {
      await* assetInfo.handler.notify(caller);
    } catch (err) {
      return #Err(#CallLedgerError({ message = Error.message(err) }));
    };
    switch (result) {
      case (?(depositInc, creditInc)) {
        let userCredit = assetInfo.handler.userCredit(caller);
        if (userCredit > 0) {
          let inc = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(caller, inc);
          ignore a.appendCredit(caller, assetId, inc);
          #Ok({
            deposit_inc = depositInc;
            credit_inc = creditInc;
            credit = a.getCredit(caller, assetId).available;
          });
        } else {
          #Err(#NotAvailable({ message = "Deposit was not detected" }));
        };
      };
      case (null) #Err(#NotAvailable({ message = "Deposit was not detected" }));
    };
  };

  public shared ({ caller }) func icrc84_deposit(args : { token : Principal; amount : Nat; from : { owner : Principal; subaccount : ?Blob }; expected_fee : ?Nat }) : async DepositResult {
    depositCounter.add(1);
    let a = U.unwrapUninit(auction);
    let assetId = switch (getAssetId(args.token)) {
      case (?aid) aid;
      case (_) throw Error.reject("Unknown token");
    };
    let assetInfo = Vec.get(assets, assetId);
    let res = await* assetInfo.handler.depositFromAllowance(caller, args.from, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(creditInc, txid)) {
        let userCredit = assetInfo.handler.userCredit(caller);
        if (userCredit > 0) {
          let credited = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(caller, credited);
          ignore a.appendCredit(caller, assetId, credited);
          #Ok({
            credit_inc = creditInc;
            txid = txid;
            credit = a.getCredit(caller, assetId).available;
          });
        } else {
          #Err(#AmountBelowMinimum({}));
        };
      };
      case (#err x) #Err(
        switch (x) {
          case (#BadFee x) #BadFee(x);
          case (#CallIcrc1LedgerError) #CallLedgerError({
            message = "Call failed";
          });
          case (#InsufficientAllowance _) #TransferError({
            message = "Insufficient allowance";
          });
          case (#InsufficientFunds _) #TransferError({
            message = "Insufficient funds";
          });
          case (_) #TransferError({ message = "Unexpected error" });
        }
      );
    };
  };

  public shared ({ caller }) func icrc84_withdraw(args : { to : { owner : Principal; subaccount : ?Blob }; amount : Nat; token : Principal; expected_fee : ?Nat }) : async WithdrawResult {
    withdrawCounter.add(1);
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let handler = Vec.get(assets, assetId).handler;
    let rollbackCredit = switch (U.unwrapUninit(auction).deductCredit(caller, assetId, args.amount)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r)) r;
    };
    let res = await* handler.withdrawFromPool(args.to, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(txid, amount)) #Ok({ txid; amount });
      case (#err err) {
        rollbackCredit();
        switch (err) {
          case (#BadFee x) #Err(#BadFee(x));
          case (#TooLowQuantity) #Err(#AmountBelowMinimum({}));
          case (#CallIcrc1LedgerError) #Err(#CallLedgerError({ message = "Call error" }));
          case (_) #Err(#CallLedgerError({ message = "Try later" }));
        };
      };
    };
  };

  // Auction API
  public shared func init() : async () {
    assert Option.isNull(auction);
    assets := Vec.map<StableAssetInfo, AssetInfo>(
      assetsDataV3,
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
            log = func(p : Principal, logEvent : TokenHandler.LogEvent) = Vec.add(tokenHandlersJournal, (x.ledgerPrincipal, p, logEvent));
          });
          decimals = x.decimals;
          symbol = x.symbol;
        };
        r.handler.unshare(x.handler);
        r;
      },
    );
    // for ((asset, id) in Vec.items(assets)) {
    //   let (symbol, decimals) = await* fetchLedgerInfo(asset.ledgerPrincipal);
    //   if (asset.decimals != decimals or asset.symbol != symbol) {
    //     Vec.put(assets, id, { asset with decimals; symbol });
    //   };
    // };
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
    a.unshare(auctionDataV6);
    auction := ?a;
    nextSessionTimestamp := Nat64.toNat(AUCTION_INTERVAL_SECONDS * (1 + Prim.time() / (AUCTION_INTERVAL_SECONDS * 1_000_000_000)));

    startTimer<system>();

    let startupTime = Prim.time();
    ignore metrics.addPullValue("uptime", "", func() = Nat64.toNat((Prim.time() - startupTime) / 1_000_000_000));
    ignore metrics.addPullValue("sessions_counter", "", func() = a.sessionsCounter);
    ignore metrics.addPullValue("assets_count", "", func() = a.assets.nAssets());
    ignore metrics.addPullValue("users_count", "", func() = a.users.nUsers());
    ignore metrics.addPullValue("users_with_credits_count", "", func() = a.users.nUsersWithCredits());
    ignore metrics.addPullValue("accounts_count", "", func() = a.credits.nAccounts());
    ignore metrics.addPullValue("quote_surplus", "", func() = a.credits.quoteSurplus);
    ignore metrics.addPullValue("next_session_timestamp", "", func() = nextSessionTimestamp);
    ignore metrics.addPullValue("total_executed_volume", "", func() = a.orders.totalQuoteVolumeProcessed);
    ignore metrics.addPullValue("total_unique_participants", "", func() = a.users.participantsArchiveSize);
    ignore metrics.addPullValue("active_unique_participants", "", func() = a.users.nUsersWithActiveOrders());
    ignore metrics.addPullValue(
      "monthly_active_participants_count",
      "",
      func() {
        let ts : Nat64 = Prim.time() - 30 * 24 * 60 * 60_000_000_000;
        var amount : Nat = 0;
        for ((_, { lastOrderPlacement }) in a.users.participantsArchive.entries()) {
          if (lastOrderPlacement > ts) {
            amount += 1;
          };
        };
        amount;
      },
    );
    ignore metrics.addPullValue("total_orders", "", func() = a.orders.ordersCounter);
    ignore metrics.addPullValue("fulfilled_orders", "", func() = a.orders.fulfilledCounter);
    ignore metrics.addPullValue("auctions_run_count", "", func() = a.assets.historyLength());
    ignore metrics.addPullValue("trading_pairs_count", "", func() = a.assets.nAssets() - 1);

    if (Vec.size(assets) == 0) {
      ignore U.requireOk(await* registerAsset_(quoteLedgerPrincipal, 0));
    } else {
      for (assetId in Iter.range(0, a.assets.nAssets() - 1)) {
        registerAssetMetrics_(assetId);
      };
    };
  };

  public shared query func getQuoteLedger() : async Principal = async quoteLedgerPrincipal;
  public shared query func nextSession() : async {
    timestamp : Nat;
    counter : Nat;
  } = async ({
    timestamp = nextSessionTimestamp;
    counter = U.unwrapUninit(auction).sessionsCounter;
  });

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

  public shared query ({ caller }) func queryDepositHistory(token : ?Principal, limit : Nat, skip : Nat) : async [DepositHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    U.unwrapUninit(auction).getDepositHistory(caller, assetId)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3));
  };

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
    manageOrdersCounter.add(1);
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
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeOrder(caller, #bid, aid, arg[i].1, arg[i].2) |> R.toUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    U.unwrapUninit(auction).replaceOrder(caller, #bid, orderId, volume : Nat, price : Float) |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId]) : async [UpperResult<(), Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<(), Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelOrder(caller, #bid, orderIds[i]) |> R.toUpper(_),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, volume : Nat, price : Float)]) : async [UpperResult<Auction.OrderId, Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.OrderId, Auction.PlaceOrderError>>(
      arg.size(),
      func(i) = switch (getAssetId(arg[i].0)) {
        case (?aid) U.unwrapUninit(auction).placeOrder(caller, #ask, aid, arg[i].1, arg[i].2) |> R.toUpper(_);
        case (_) #Err(#UnknownAsset);
      },
    );
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float) : async UpperResult<Auction.OrderId, Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    U.unwrapUninit(auction).replaceOrder(caller, #ask, orderId, volume : Nat, price : Float) |> R.toUpper(_);
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId]) : async [UpperResult<(), Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    let a = U.unwrapUninit(auction);
    Array.tabulate<UpperResult<(), Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = a.cancelOrder(caller, #ask, orderIds[i]) |> R.toUpper(_),
    );
  };

  public func updateTokenHandlerFee(ledger : Principal) : async ?Nat = async switch (getAssetId(ledger)) {
    case (?aid) await* Vec.get(assets, aid) |> _.handler.fetchFee();
    case (_) throw Error.reject("Unknown asset");
  };

  public query func isTokenHandlerFrozen(ledger : Principal) : async Bool = async switch (getAssetId(ledger)) {
    case (?aid) Vec.get(assets, aid) |> _.handler.isFrozen();
    case (_) throw Error.reject("Unknown asset");
  };

  public query func queryTokenHandlerState(ledger : Principal) : async {
    ledger : {
      fee : Nat;
    };
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

  public query func queryUserCreditsInTokenHandler(ledger : Principal, user : Principal) : async Int {
    switch (getAssetId(ledger)) {
      case (?aid) Vec.get(assets, aid) |> _.handler.userCredit(user);
      case (_) throw Error.reject("Unknown asset");
    };
  };

  public query func queryTokenHandlerNotificationsOnPause(ledger : Principal) : async Bool {
    switch (getAssetId(ledger)) {
      case (?aid) Vec.get(assets, aid) |> _.handler.notificationsOnPause();
      case (_) throw Error.reject("Unknown asset");
    };
  };

  public query func queryTokenHandlerDepositRegistry(ledger : Principal) : async (sum : Nat, size : Nat, minimum : Nat, [(Principal, { value : Nat; lock : Bool })]) {
    let sharedData = switch (getAssetId(ledger)) {
      case (?aid) Vec.get(assets, aid) |> _.handler.share();
      case (_) throw Error.reject("Unknown asset");
    };
    let locks = RBTree.RBTree<Principal, { var value : Nat; var lock : Bool }>(Principal.compare);
    locks.unshare(sharedData.0.0.0);
    let iter = locks.entries();
    let items : Vec.Vector<(Principal, { value : Nat; lock : Bool })> = Vec.new();
    label l while (true) {
      switch (iter.next()) {
        case (?x) Vec.add(items, (x.0, { value = x.1.value; lock = x.1.lock }));
        case (null) break l;
      };
    };
    (sharedData.0.0.1, sharedData.0.0.2, sharedData.0.0.3, Vec.toArray(items));
  };

  public query func queryTokenHandlerNotificationLock(ledger : Principal, user : Principal) : async ?{
    value : Nat;
    lock : Bool;
  } {
    let sharedData = switch (getAssetId(ledger)) {
      case (?aid) Vec.get(assets, aid) |> _.handler.share();
      case (_) throw Error.reject("Unknown asset");
    };
    let locks = RBTree.RBTree<Principal, { var value : Nat; var lock : Bool }>(Principal.compare);
    locks.unshare(sharedData.0.0.0);
    switch (locks.get(user)) {
      case (?v) ?{ value = v.value; lock = v.lock };
      case (null) null;
    };
  };

  public query func queryTokenHandlerJournal(ledger : Principal, limit : Nat, skip : Nat) : async [(Principal, TokenHandler.LogEvent)] {
    Vec.vals(tokenHandlersJournal)
    |> Iter.filter<(Principal, Principal, TokenHandler.LogEvent)>(_, func(l, _, _) = Principal.equal(l, ledger))
    |> Iter.map<(Principal, Principal, TokenHandler.LogEvent), (Principal, TokenHandler.LogEvent)>(_, func(_, p, e) = (p, e))
    |> U.sliceIter(_, limit, skip);
  };

  public query func listAdmins() : async [Principal] = async adminsMap.entries()
  |> Iter.map<(Principal, ()), Principal>(_, func((p, _)) = p)
  |> Iter.toArray(_);

  private func assertAdminAccess(principal : Principal) : async* () {
    if (adminsMap.get(principal) == null) {
      throw Error.reject("No Access for this principal " # Principal.toText(principal));
    };
  };

  private func assertAdminAccessSync(principal : Principal) : () {
    if (adminsMap.get(principal) == null) {
      Prim.trap("No Access for this principal " # Principal.toText(principal));
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
    if (assetId == quoteAssetId) return;
    let asset = U.unwrapUninit(auction).assets.getAsset(assetId);
    let tokenHandler = Vec.get(assets, assetId).handler;

    let priceMultiplier = 10 ** Float.fromInt(Vec.get(assets, assetId).decimals);
    let renderPrice = func(price : Float) : Nat = Int.abs(Float.toInt(price * priceMultiplier));
    let labels = "asset_id=\"" # Vec.get(assets, assetId).symbol # "\"";

    ignore metrics.addPullValue("asks_count", labels, func() = asset.asks.size);
    ignore metrics.addPullValue("asks_volume", labels, func() = asset.asks.totalVolume);
    ignore metrics.addPullValue("bids_count", labels, func() = asset.bids.size);
    ignore metrics.addPullValue("bids_volume", labels, func() = asset.bids.totalVolume);
    ignore metrics.addPullValue("processing_instructions", labels, func() = asset.lastProcessingInstructions);

    ignore metrics.addPullValue(
      "clearing_price",
      labels,
      func() = U.unwrapUninit(auction).indicativeAssetStats(assetId).clearingPrice
      |> renderPrice(_),
    );
    ignore metrics.addPullValue("clearing_volume", labels, func() = U.unwrapUninit(auction).indicativeAssetStats(assetId).clearingVolume);

    ignore metrics.addPullValue(
      "last_price",
      labels,
      func() = U.unwrapUninit(auction).getPriceHistory(?assetId).next()
      |> (
        switch (_) {
          case (?item) renderPrice(item.4);
          case (null) 0;
        }
      ),
    );
    ignore metrics.addPullValue(
      "last_volume",
      labels,
      func() = U.unwrapUninit(auction).getPriceHistory(?assetId).next()
      |> (
        switch (_) {
          case (?item) item.3;
          case (null) 0;
        }
      ),
    );
    ignore metrics.addPullValue(
      "token_handler_locks",
      labels,
      func() {
        let tree = tokenHandler.share().0.0.0;
        var nLocks = 0;
        for ((_, x) in RBTree.iter(tree, #fwd)) {
          if (x.lock) {
            nLocks += 1;
          };
        };
        nLocks;
      },
    );
    ignore metrics.addPullValue(
      "token_handler_frozen",
      labels,
      func() = if (tokenHandler.isFrozen()) { 1 } else { 0 },
    );
  };

  private func fetchLedgerInfo(ledger : Principal) : async* (symbol : Text, decimals : Nat) {
    let canister = actor (Principal.toText(ledger)) : (actor { icrc1_decimals : () -> async Nat8; icrc1_symbol : () -> async Text });
    let decimals = try {
      Nat8.toNat(await canister.icrc1_decimals());
    } catch (err) {
      throw err;
    };
    let symbol = try {
      await canister.icrc1_symbol();
    } catch (err) {
      throw err;
    };
    (symbol, decimals);
  };

  private func registerAsset_(ledgerPrincipal : Principal, minAskVolume : Nat) : async* R.Result<Nat, RegisterAssetError> {
    let (symbol, decimals) = await* fetchLedgerInfo(ledgerPrincipal);
    for ((assetInfo, i) in Vec.items(assets)) {
      if (Principal.equal(ledgerPrincipal, assetInfo.ledgerPrincipal)) return #err(#AlreadyRegistered(i));
    };
    let id = Vec.size(assets);
    assert id == U.unwrapUninit(auction).assets.nAssets();
    (actor (Principal.toText(ledgerPrincipal)) : ICRC1.ICRC1Ledger)
    |> {
      balance_of = _.icrc1_balance_of;
      fee = _.icrc1_fee;
      transfer = _.icrc1_transfer;
      transfer_from = _.icrc2_transfer_from;
    }
    |> {
      ledgerPrincipal;
      minAskVolume;
      handler = TokenHandler.TokenHandler({
        ledgerApi = _;
        ownPrincipal = Principal.fromActor(self);
        initialFee = 0;
        triggerOnNotifications = true;
        log = func(p : Principal, logEvent : TokenHandler.LogEvent) = Vec.add(tokenHandlersJournal, (ledgerPrincipal, p, logEvent));
      });
      symbol;
      decimals;
    }
    |> Vec.add<AssetInfo>(assets, _);
    U.unwrapUninit(auction).registerAssets(1);
    registerAssetMetrics_(id);
    #ok(id);
  };

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* assertAdminAccess(caller);
    let res = await* registerAsset_(ledger, minAskVolume);
    R.toUpper(res);
  };

  public shared ({ caller }) func wipePriceHistory(icrc1Ledger : Principal) : async () {
    await* assertAdminAccess(caller);
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    let newHistory : Vec.Vector<Auction.PriceHistoryItem> = Vec.new();
    for (x in Vec.vals(U.unwrapUninit(auction).assets.history)) {
      if (x.2 != assetId) {
        Vec.add(newHistory, x);
      };
    };
    U.unwrapUninit(auction).assets.history := newHistory;
  };

  public shared ({ caller }) func wipeOrders() : async () {
    await* assertAdminAccess(caller);
    let a = U.unwrapUninit(auction);
    for ((p, _) in a.users.users.entries()) {
      ignore a.manageOrders(p, ? #all(null), []);
    };
  };

  public shared ({ caller }) func wipeUsers() : async () {
    await* assertAdminAccess(caller);
    let a = U.unwrapUninit(auction);
    for ((p, _) in a.users.users.entries()) {
      a.users.users.delete(p);
    };
    for (asset in Vec.vals(a.assets.assets)) {
      asset.asks.queue := List.nil();
      asset.asks.size := 0;
      asset.asks.totalVolume := 0;
      asset.bids.queue := List.nil();
      asset.bids.size := 0;
      asset.bids.totalVolume := 0;
    };
  };

  public shared query ({ caller }) func queryUserCredits(p : Principal) : async [(Principal, Auction.CreditInfo)] {
    assertAdminAccessSync(caller);
    U.unwrapUninit(auction).getCredits(p) |> Array.tabulate<(Principal, Auction.CreditInfo)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
  };

  public shared query ({ caller }) func queryUserBids(p : Principal) : async [(Auction.OrderId, Order)] {
    assertAdminAccessSync(caller);
    U.unwrapUninit(auction).getOrders(p, #bid, null)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
  };

  public shared query ({ caller }) func queryUserAsks(p : Principal) : async [(Auction.OrderId, Order)] {
    assertAdminAccessSync(caller);
    U.unwrapUninit(auction).getOrders(p, #ask, null)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = mapOrder(_ [i]));
  };

  public shared query ({ caller }) func queryUserDepositHistory(p : Principal, token : ?Principal, limit : Nat, skip : Nat) : async [DepositHistoryItem] {
    assertAdminAccessSync(caller);
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    U.unwrapUninit(auction).getDepositHistory(p, assetId)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3));
  };

  public shared query ({ caller }) func queryUserTransactionHistory(p : Principal, token : ?Principal, limit : Nat, skip : Nat) : async [TransactionHistoryItem] {
    assertAdminAccessSync(caller);
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    U.unwrapUninit(auction).getTransactionHistory(p, assetId)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, Vec.get(assets, x.3).ledgerPrincipal, x.4, x.5));
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
    if (nextAssetIdToProcess == 0) {
      let startTimeDiff : Int = Nat64.toNat(Prim.time() / 1_000_000) - nextSessionTimestamp * 1_000;
      sessionStartTimeGauge.update(Int.max(startTimeDiff, 0) |> Int.abs(_));
      let next = Nat64.toNat(AUCTION_INTERVAL_SECONDS * (1 + Prim.time() / (AUCTION_INTERVAL_SECONDS * 1_000_000_000)));
      if (next == nextSessionTimestamp) {
        // if auction started before expected time
        nextSessionTimestamp += Nat64.toNat(AUCTION_INTERVAL_SECONDS);
      } else {
        nextSessionTimestamp := next;
      };
    };
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
        assetsDataV3 := Vec.map<AssetInfo, StableAssetInfo>(
          assets,
          func(x) = {
            ledgerPrincipal = x.ledgerPrincipal;
            minAskVolume = x.minAskVolume;
            handler = x.handler.share();
            decimals = x.decimals;
            symbol = x.symbol;
          },
        );
        auctionDataV6 := a.share();
        ptData := metrics.share();
      };
      case (null) {};
    };
    stableAdminsMap := adminsMap.share();
  };

  system func postupgrade() {
    metrics.unshare(ptData);
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

  // each 2 minutes
  let AUCTION_INTERVAL_SECONDS : Nat64 = 120;
  var nextSessionTimestamp = 0;

  func startTimer<system>() {
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
    ) |> Timer.setTimer<system>(#seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000) % AUCTION_INTERVAL_SECONDS)), _);
  };

};
