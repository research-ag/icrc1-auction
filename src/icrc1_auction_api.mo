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
import ICRC84Auction "./icrc84_auction";
import PT "mo:promtracker";
import TokenHandler "mo:token_handler";
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

  type THStableDataV1 = (((RBTree.Tree<Principal, { var value : Nat; var lock : Bool }>, Nat, Nat, Nat), Nat, Nat, Nat, Nat), ([(Principal, Int)], Int, Int));
  type THStableDataV2 = ([(Principal, Int)], Int, Int);

  stable var assetsDataV3 : Vec.Vector<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : THStableDataV1; symbol : Text; decimals : Nat }> = Vec.new();
  stable var assetsDataV4 : Vec.Vector<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : THStableDataV2; symbol : Text; decimals : Nat }> = Vec.map<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : THStableDataV1; symbol : Text; decimals : Nat }, { ledgerPrincipal : Principal; minAskVolume : Nat; handler : THStableDataV2; symbol : Text; decimals : Nat }>(
    assetsDataV3,
    func(ad) = { ad with handler = ad.handler.1 },
  );
  stable var assetsDataV5 : Vec.Vector<StableAssetInfo> = Vec.map<{ ledgerPrincipal : Principal; minAskVolume : Nat; handler : THStableDataV2; symbol : Text; decimals : Nat }, StableAssetInfo>(
    assetsDataV4,
    func(ad) = { ad with handler = ((((#leaf, 0, 0, 1), 0), 0), ad.handler) },
  );

  stable var auctionDataV3 : Auction.StableDataV3 = Auction.defaultStableDataV3();
  stable var auctionDataV4 : Auction.StableDataV4 = Auction.migrateStableDataV4(auctionDataV3);
  stable var auctionDataV5 : Auction.StableDataV5 = Auction.migrateStableDataV5(auctionDataV4);
  stable var auctionDataV6 : Auction.StableDataV6 = Auction.migrateStableDataV6(auctionDataV5);
  stable var auctionDataV7 : Auction.StableDataV7 = Auction.migrateStableDataV7(auctionDataV6);

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
    #AlreadyRegistered;
  };

  type Order = {
    icrc1Ledger : Principal;
    price : Float;
    volume : Nat;
  };
  func mapOrder(order : Auction.Order) : Order = ({
    icrc1Ledger = Vec.get(assets, order.assetId).ledgerPrincipal;
    price = order.price;
    volume = order.volume;
  });

  type UserOrder = {
    user : Principal;
    price : Float;
    volume : Nat;
  };
  func mapUserOrder(order : Auction.Order) : UserOrder = ({
    user = order.user;
    price = order.price;
    volume = order.volume;
  });

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

  let quoteAssetId : Auction.AssetId = 0;

  func createAssetInfo_(ledgerPrincipal : Principal, minAskVolume : Nat, decimals : Nat, symbol : Text, tokenHandlerStableData : ?TokenHandler.StableData) : AssetInfo {
    let ai = TokenHandler.buildLedgerApi(ledgerPrincipal)
    |> {
      ledgerPrincipal = ledgerPrincipal;
      minAskVolume = minAskVolume;
      handler = TokenHandler.TokenHandler({
        ledgerApi = _;
        ownPrincipal = Principal.fromActor(self);
        initialFee = 0;
        triggerOnNotifications = true;
        log = func(p : Principal, logEvent : TokenHandler.LogEvent) = Vec.add(tokenHandlersJournal, (ledgerPrincipal, p, logEvent));
      });
      decimals = decimals;
      symbol = symbol;
    };
    switch (tokenHandlerStableData) {
      case (?d) ai.handler.unshare(d);
      case (null) {};
    };
    ai;
  };

  let assets : Vec.Vector<AssetInfo> = Vec.map<StableAssetInfo, AssetInfo>(
    assetsDataV5,
    func(x) = createAssetInfo_(x.ledgerPrincipal, x.minAskVolume, x.decimals, x.symbol, ?x.handler),
  );
  let auction : Auction.Auction = Auction.Auction(
    0,
    {
      volumeStepLog10 = 3; // minimum quote volume step 1_000
      minVolumeSteps = 5; // minimum quote volume is 5_000
      priceMaxDigits = 5;
      minAskVolume = func(assetId, _) = Vec.get(assets, assetId).minAskVolume;
      performanceCounter = Prim.performanceCounter;
    },
  );
  auction.unshare(auctionDataV7);

  // each 2 minutes
  let AUCTION_INTERVAL_SECONDS : Nat64 = 120;
  var nextSessionTimestamp = Nat64.toNat(AUCTION_INTERVAL_SECONDS * (1 + Prim.time() / (AUCTION_INTERVAL_SECONDS * 1_000_000_000)));

  private func registerAsset_(ledgerPrincipal : Principal, minAskVolume : Nat) : async* R.Result<Nat, RegisterAssetError> {
    let canister = actor (Principal.toText(ledgerPrincipal)) : (actor { icrc1_decimals : () -> async Nat8; icrc1_symbol : () -> async Text });
    let decimalsCall = canister.icrc1_decimals();
    let symbolCall = canister.icrc1_symbol();
    let decimals = Nat8.toNat(await decimalsCall);
    let symbol = await symbolCall;

    if (Vec.forSome<AssetInfo>(assets, func(a) = Principal.equal(ledgerPrincipal, a.ledgerPrincipal))) {
      return #err(#AlreadyRegistered);
    };
    let id = Vec.size(assets);
    assert id == auction.assets.nAssets();
    createAssetInfo_(ledgerPrincipal, minAskVolume, decimals, symbol, null) |> Vec.add<AssetInfo>(assets, _);
    auction.registerAssets(1);
    registerAssetMetrics_(id);
    #ok(id);
  };

  let metrics = PT.PromTracker("", 65);
  metrics.addSystemValues();
  let sessionStartTimeGauge = metrics.addGauge("session_start_time_offset_ms", "", #none, [0, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000], false);
  let startupTime = Prim.time();
  ignore metrics.addPullValue("uptime", "", func() = Nat64.toNat((Prim.time() - startupTime) / 1_000_000_000));
  ignore metrics.addPullValue("sessions_counter", "", func() = auction.sessionsCounter);
  ignore metrics.addPullValue("assets_count", "", func() = auction.assets.nAssets());
  ignore metrics.addPullValue("users_count", "", func() = auction.users.nUsers());
  ignore metrics.addPullValue("users_with_credits_count", "", func() = auction.users.nUsersWithCredits());
  ignore metrics.addPullValue("accounts_count", "", func() = auction.credits.nAccounts());
  ignore metrics.addPullValue("quote_surplus", "", func() = auction.credits.quoteSurplus);
  ignore metrics.addPullValue("next_session_timestamp", "", func() = nextSessionTimestamp);
  ignore metrics.addPullValue("total_unique_participants", "", func() = auction.users.participantsArchiveSize);
  ignore metrics.addPullValue("active_unique_participants", "", func() = auction.users.nUsersWithActiveOrders());
  ignore metrics.addPullValue(
    "monthly_active_participants_count",
    "",
    func() {
      let ts : Nat64 = Prim.time() - 30 * 24 * 60 * 60_000_000_000;
      var amount : Nat = 0;
      for ((_, { lastOrderPlacement }) in auction.users.participantsArchive.entries()) {
        if (lastOrderPlacement > ts) {
          amount += 1;
        };
      };
      amount;
    },
  );
  ignore metrics.addPullValue("total_orders", "", func() = auction.orders.ordersCounter);
  ignore metrics.addPullValue("auctions_run_count", "", func() = auction.assets.historyLength());
  ignore metrics.addPullValue("trading_pairs_count", "", func() = auction.assets.nAssets() - 1);
  ignore metrics.addPullValue("total_points_supply", "", func() = auction.getTotalLoyaltyPointsSupply());

  // call stats
  let notifyCounter = metrics.addCounter("total_calls__icrc84_notify", "", true);
  let depositCounter = metrics.addCounter("total_calls__icrc84_deposit", "", true);
  let withdrawCounter = metrics.addCounter("total_calls__icrc84_withdraw", "", true);
  let manageOrdersCounter = metrics.addCounter("total_calls__manageOrders", "", true);
  let orderPlacementCounter = metrics.addCounter("total_calls__order_placement", "", true);
  let orderReplacementCounter = metrics.addCounter("total_calls__order_replacement", "", true);
  let orderCancellationCounter = metrics.addCounter("total_calls__order_cancellation", "", true);

  private func registerAssetMetrics_(assetId : Auction.AssetId) {
    if (assetId == quoteAssetId) return;
    let asset = auction.assets.getAsset(assetId);
    let tokenHandler = Vec.get(assets, assetId).handler;

    let priceMultiplier = 10 ** Float.fromInt(Vec.get(assets, assetId).decimals);
    let renderPrice = func(price : Float) : Nat = Int.abs(Float.toInt(price * priceMultiplier));
    let labels = "asset_id=\"" # Vec.get(assets, assetId).symbol # "\"";

    ignore metrics.addPullValue("asks_count", labels, func() = asset.asks.size);
    ignore metrics.addPullValue("asks_volume", labels, func() = asset.asks.totalVolume);
    ignore metrics.addPullValue("bids_count", labels, func() = asset.bids.size);
    ignore metrics.addPullValue("bids_volume", labels, func() = asset.bids.totalVolume);
    ignore metrics.addPullValue("processing_instructions", labels, func() = asset.lastProcessingInstructions);
    ignore metrics.addPullValue("total_executed_volume_base", labels, func() = asset.totalExecutedVolumeBase);
    ignore metrics.addPullValue("total_executed_volume_quote", labels, func() = asset.totalExecutedVolumeQuote);
    ignore metrics.addPullValue("total_executed_orders", labels, func() = asset.totalExecutedOrders);

    ignore metrics.addPullValue(
      "clearing_price",
      labels,
      func() = auction.indicativeAssetStats(assetId)
      |> (switch (_.clearing) { case (#match x) { x.price }; case (_) { 0.0 } })
      |> renderPrice(_),
    );
    ignore metrics.addPullValue(
      "clearing_volume",
      labels,
      func() = auction.indicativeAssetStats(assetId)
      |> (switch (_.clearing) { case (#match x) { x.volume }; case (_) { 0 } }),
    );

    ignore metrics.addPullValue(
      "last_price",
      labels,
      func() = auction.getPriceHistory(?assetId, #desc, false).next()
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
      func() = auction.getPriceHistory(?assetId, #desc, false).next()
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
      func() = tokenHandler.state().depositManager.nLocks,
    );
    ignore metrics.addPullValue(
      "token_handler_frozen",
      labels,
      func() = if (tokenHandler.isFrozen()) { 1 } else { 0 },
    );
  };
  for (assetId in Iter.range(0, auction.assets.nAssets() - 1)) {
    registerAssetMetrics_(assetId);
  };
  metrics.unshare(ptData);

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

  public shared query ({ caller }) func icrc84_query(arg : [Principal]) : async [(
    Principal,
    {
      credit : Int;
      tracked_deposit : {
        #Ok : Nat;
        #Err : { #NotAvailable : { message : Text } };
      };
    },
  )] {
    let tokens : [Principal] = switch (arg.size()) {
      case (0) Vec.map<AssetInfo, Principal>(assets, func({ ledgerPrincipal }) = ledgerPrincipal) |> Vec.toArray(_);
      case (_) arg;
    };
    let ret : Vec.Vector<(Principal, { credit : Int; tracked_deposit : { #Ok : Nat; #Err : { #NotAvailable : { message : Text } } } })> = Vec.new();
    for (token in tokens.vals()) {
      let ?aid = getAssetId(token) else throw Error.reject("Unknown token " # Principal.toText(token));
      let credit = U.unwrapUninit(auction).getCredit(caller, aid).available;
      if (credit > 0) {
        let tracked_deposit = switch (Vec.get(assets, aid).handler.trackedDeposit(caller)) {
          case (?d) #Ok(d);
          case (null) #Err(#NotAvailable({ message = "Tracked deposit is not known" }));
        };
        Vec.add(ret, (token, { credit; tracked_deposit }));
      };
    };
    Vec.toArray(ret);
  };

  public shared ({ caller }) func icrc84_notify(args : { token : Principal }) : async NotifyResult {
    notifyCounter.add(1);
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
          ignore auction.appendCredit(caller, assetId, inc);
          assert auction.appendLoyaltyPoints(caller, #wallet);
          #Ok({
            deposit_inc = depositInc;
            credit_inc = creditInc;
            credit = auction.getCredit(caller, assetId).available;
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
    let ?assetId = getAssetId(args.token) else throw Error.reject("Unknown token");
    let assetInfo = Vec.get(assets, assetId);
    let res = await* assetInfo.handler.depositFromAllowance(caller, args.from, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(creditInc, txid)) {
        let userCredit = assetInfo.handler.userCredit(caller);
        if (userCredit > 0) {
          let credited = Int.abs(userCredit);
          assert assetInfo.handler.debitUser(caller, credited);
          ignore auction.appendCredit(caller, assetId, credited);
          assert auction.appendLoyaltyPoints(caller, #wallet);
          #Ok({
            credit_inc = creditInc;
            txid = txid;
            credit = auction.getCredit(caller, assetId).available;
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
    let (rollbackCredit, doneCallback) = switch (auction.deductCredit(caller, assetId, args.amount)) {
      case (#err _) return #Err(#InsufficientCredit({}));
      case (#ok(_, r, d)) (r, d);
    };
    let res = await* handler.withdrawFromPool(args.to, args.amount, args.expected_fee);
    switch (res) {
      case (#ok(txid, amount)) {
        doneCallback();
        assert auction.appendLoyaltyPoints(caller, #wallet);
        #Ok({ txid; amount });
      };
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

  public shared query func getQuoteLedger() : async Principal = async quoteLedgerPrincipal;
  public shared query func nextSession() : async {
    timestamp : Nat;
    counter : Nat;
  } = async ({
    timestamp = nextSessionTimestamp;
    counter = auction.sessionsCounter;
  });

  public shared query func settings() : async {
    orderQuoteVolumeMinimum : Nat;
    orderQuoteVolumeStep : Nat;
    orderPriceDigitsLimit : Nat;
  } {
    {
      orderQuoteVolumeMinimum = auction.orders.minQuoteVolume;
      orderQuoteVolumeStep = auction.orders.quoteVolumeStep;
      orderPriceDigitsLimit = auction.orders.priceMaxDigits;
    };
  };

  public shared query func indicativeStats(icrc1Ledger : Principal) : async Auction.IndicativeStats {
    if (icrc1Ledger == quoteLedgerPrincipal) throw Error.reject("Unknown asset");
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    auction.indicativeAssetStats(assetId);
  };

  public shared query func totalPointsSupply() : async Nat = async auction.getTotalLoyaltyPointsSupply();

  public shared query ({ caller }) func queryCredit(icrc1Ledger : Principal) : async (Auction.CreditInfo, Nat) {
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    (auction.getCredit(caller, assetId), auction.getAssetSessionNumber(assetId));
  };

  public shared query ({ caller }) func queryCredits() : async [(Principal, Auction.CreditInfo, Nat)] {
    auction.getCredits(caller)
    |> Array.tabulate<(Principal, Auction.CreditInfo, Nat)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1, auction.getAssetSessionNumber(_ [i].0)));
  };

  public shared query ({ caller }) func queryPoints() : async Nat {
    auction.getLoyaltyPoints(caller);
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

  public shared query ({ caller }) func queryTokenBids(ledger : Principal) : async ([(Auction.OrderId, Order)], Nat) {
    let ?assetId = getAssetId(ledger) else return ([], auction.sessionsCounter);

    auction.getOrders(caller, #bid, ?assetId)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)))
    |> (_, auction.getAssetSessionNumber(assetId));
  };

  public shared query ({ caller }) func queryBids() : async ([(Auction.OrderId, Order, Nat)]) {
    auction.getOrders(caller, #bid, null)
    |> Array.tabulate<(Auction.OrderId, Order, Nat)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1), auction.getAssetSessionNumber(_ [i].1.assetId)));
  };

  public shared query ({ caller }) func queryTokenAsks(ledger : Principal) : async ([(Auction.OrderId, Order)], Nat) {
    let ?assetId = getAssetId(ledger) else return ([], auction.sessionsCounter);

    auction.getOrders(caller, #ask, ?assetId)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)))
    |> (_, auction.getAssetSessionNumber(assetId));
  };

  public shared query ({ caller }) func queryAsks() : async ([(Auction.OrderId, Order, Nat)]) {
    auction.getOrders(caller, #ask, null)
    |> Array.tabulate<(Auction.OrderId, Order, Nat)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1), auction.getAssetSessionNumber(_ [i].1.assetId)));
  };

  public shared query ({ caller }) func queryDepositHistory(token : ?Principal, limit : Nat, skip : Nat) : async [DepositHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    auction.getDepositHistory(caller, assetId, #desc)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3));
  };

  public shared query ({ caller }) func queryTransactionHistory(token : ?Principal, limit : Nat, skip : Nat) : async [TransactionHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    auction.getTransactionHistory(caller, assetId, #desc)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, Vec.get(assets, x.3).ledgerPrincipal, x.4, x.5));
  };

  public shared query func queryPriceHistory(token : ?Principal, limit : Nat, skip : Nat, skipEmpty : Bool) : async [PriceHistoryItem] {
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    auction.getPriceHistory(assetId, #desc, skipEmpty)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.PriceHistoryItem, PriceHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3, x.4));
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
    expectedSessionNumber : ?Nat,
  ) : async UpperResult<[Auction.OrderId], ICRC84Auction.ManageOrdersError> {
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
    auction.manageOrders(caller, cancellationArg, Array.freeze(placementArg), expectedSessionNumber)
    |> ICRC84Auction.mapManageOrdersResult(_, getIcrc1Ledger);
  };

  public shared ({ caller }) func placeBids(arg : [(ledger : Principal, volume : Nat, price : Float)], expectedSessionNumber : ?Nat) : async [UpperResult<Auction.OrderId, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.OrderId, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #bid, assetId, arg[i].1, arg[i].2, expectedSessionNumber)
        |> ICRC84Auction.mapPlaceOrderResult(_, getIcrc1Ledger);
      },
    );
  };

  public shared ({ caller }) func replaceBid(orderId : Auction.OrderId, volume : Nat, price : Float, expectedSessionNumber : ?Nat) : async UpperResult<Auction.OrderId, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    auction.replaceOrder(caller, #bid, orderId, volume : Nat, price : Float, expectedSessionNumber)
    |> ICRC84Auction.mapReplaceOrderResult(_, getIcrc1Ledger);
  };

  public shared ({ caller }) func cancelBids(orderIds : [Auction.OrderId], expectedSessionNumber : ?Nat) : async [UpperResult<(), ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<(), ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #bid, orderIds[i], expectedSessionNumber) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  public shared ({ caller }) func placeAsks(arg : [(ledger : Principal, volume : Nat, price : Float)], expectedSessionNumber : ?Nat) : async [UpperResult<Auction.OrderId, ICRC84Auction.PlaceOrderError>] {
    orderPlacementCounter.add(1);
    Array.tabulate<UpperResult<Auction.OrderId, ICRC84Auction.PlaceOrderError>>(
      arg.size(),
      func(i) {
        let ?assetId = getAssetId(arg[i].0) else return #Err(#UnknownAsset);
        auction.placeOrder(caller, #ask, assetId, arg[i].1, arg[i].2, expectedSessionNumber)
        |> ICRC84Auction.mapPlaceOrderResult(_, getIcrc1Ledger);
      },
    );
  };

  public shared ({ caller }) func replaceAsk(orderId : Auction.OrderId, volume : Nat, price : Float, expectedSessionNumber : ?Nat) : async UpperResult<Auction.OrderId, ICRC84Auction.ReplaceOrderError> {
    orderReplacementCounter.add(1);
    auction.replaceOrder(caller, #ask, orderId, volume : Nat, price : Float, expectedSessionNumber)
    |> ICRC84Auction.mapReplaceOrderResult(_, getIcrc1Ledger);
  };

  public shared ({ caller }) func cancelAsks(orderIds : [Auction.OrderId], expectedSessionNumber : ?Nat) : async [UpperResult<(), ICRC84Auction.CancelOrderError>] {
    orderCancellationCounter.add(1);
    Array.tabulate<UpperResult<(), ICRC84Auction.CancelOrderError>>(
      orderIds.size(),
      func(i) = auction.cancelOrder(caller, #ask, orderIds[i], expectedSessionNumber) |> ICRC84Auction.mapCancelOrderResult(_, getIcrc1Ledger),
    );
  };

  public func updateTokenHandlerFee(ledger : Principal) : async ?Nat {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    await* Vec.get(assets, assetId) |> _.handler.fetchFee();
  };

  public query func isTokenHandlerFrozen(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.isFrozen();
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
    depositManager : {
      paused : Bool;
      fee : { ledger : Nat; deposit : Nat; surcharge : Nat };
      flow : { credited : Nat };
      totalConsolidated : Nat;
      funds : {
        deposited : Nat;
        underway : Nat;
        queued : Nat;
      };
      nDeposits : Nat;
      nLocks : Nat;
    };
  } {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.state();
  };

  public query func queryUserCreditsInTokenHandler(ledger : Principal, user : Principal) : async Int {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.userCredit(user);
  };

  public query func queryTokenHandlerNotificationsOnPause(ledger : Principal) : async Bool {
    let ?assetId = getAssetId(ledger) else throw Error.reject("Unknown asset");
    Vec.get(assets, assetId) |> _.handler.notificationsOnPause();
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

  public shared ({ caller }) func registerAsset(ledger : Principal, minAskVolume : Nat) : async UpperResult<Nat, RegisterAssetError> {
    await* assertAdminAccess(caller);
    let res = await* registerAsset_(ledger, minAskVolume);
    R.toUpper(res);
  };

  public shared ({ caller }) func wipePriceHistory(icrc1Ledger : Principal) : async () {
    await* assertAdminAccess(caller);
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    let newHistory : Vec.Vector<Auction.PriceHistoryItem> = Vec.new();
    for (x in Vec.vals(auction.assets.history)) {
      if (x.2 != assetId) {
        Vec.add(newHistory, x);
      };
    };
    auction.assets.history := newHistory;
  };

  public shared ({ caller }) func wipeOrders() : async () {
    await* assertAdminAccess(caller);
    for ((p, _) in auction.users.users.entries()) {
      ignore auction.manageOrders(p, ? #all(null), [], null);
    };
  };

  public shared ({ caller }) func wipeUsers() : async () {
    await* assertAdminAccess(caller);
    for ((p, _) in auction.users.users.entries()) {
      auction.users.users.delete(p);
    };
    for (asset in Vec.vals(auction.assets.assets)) {
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
    auction.getCredits(p) |> Array.tabulate<(Principal, Auction.CreditInfo)>(_.size(), func(i) = (getIcrc1Ledger(_ [i].0), _ [i].1));
  };

  public shared query ({ caller }) func queryUserBids(p : Principal) : async [(Auction.OrderId, Order)] {
    assertAdminAccessSync(caller);
    auction.getOrders(p, #bid, null)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)));
  };

  public shared query ({ caller }) func queryUserAsks(p : Principal) : async [(Auction.OrderId, Order)] {
    assertAdminAccessSync(caller);
    auction.getOrders(p, #ask, null)
    |> Array.tabulate<(Auction.OrderId, Order)>(_.size(), func(i) = (_ [i].0, mapOrder(_ [i].1)));
  };

  public shared query ({ caller }) func queryOrderBook(icrc1Ledger : Principal) : async {
    asks : [(Auction.OrderId, UserOrder)];
    bids : [(Auction.OrderId, UserOrder)];
  } {
    assertAdminAccessSync(caller);
    let ?assetId = getAssetId(icrc1Ledger) else throw Error.reject("Unknown asset");
    {
      asks = auction.getOrderBook(assetId, #ask)
      |> Array.tabulate<(Auction.OrderId, UserOrder)>(_.size(), func(i) = (_ [i].0, mapUserOrder(_ [i].1)));
      bids = auction.getOrderBook(assetId, #bid)
      |> Array.tabulate<(Auction.OrderId, UserOrder)>(_.size(), func(i) = (_ [i].0, mapUserOrder(_ [i].1)));
    };
  };

  public shared query ({ caller }) func queryUserDepositHistory(p : Principal, token : ?Principal, limit : Nat, skip : Nat) : async [DepositHistoryItem] {
    assertAdminAccessSync(caller);
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    auction.getDepositHistory(p, assetId, #desc)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.DepositHistoryItem, DepositHistoryItem>(_, func(x) = (x.0, x.1, Vec.get(assets, x.2).ledgerPrincipal, x.3));
  };

  public shared query ({ caller }) func queryUserTransactionHistory(p : Principal, token : ?Principal, limit : Nat, skip : Nat) : async [TransactionHistoryItem] {
    assertAdminAccessSync(caller);
    let assetId : ?Auction.AssetId = switch (token) {
      case (null) null;
      case (?aid) getAssetId(aid);
    };
    auction.getTransactionHistory(p, assetId, #desc)
    |> U.sliceIter(_, limit, skip)
    |> Array.map<Auction.TransactionHistoryItem, TransactionHistoryItem>(_, func(x) = (x.0, x.1, x.2, Vec.get(assets, x.3).ledgerPrincipal, x.4, x.5));
  };

  // Auction processing functionality

  var nextAssetIdToProcess : Nat = 0;
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
    switch (processAssetsChunk(auction, nextAssetIdToProcess)) {
      case (#done) {
        auction.sessionsCounter += 1;
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
    switch (req.method, path) {
      case ("GET", "/metrics") metrics.renderExposition("canister=\"" # PT.shortName(self) # "\"") |> HTTP.renderPlainText(_);
      case (_) HTTP.render400();
    };
  };

  system func preupgrade() {
    assetsDataV5 := Vec.map<AssetInfo, StableAssetInfo>(
      assets,
      func(x) = {
        ledgerPrincipal = x.ledgerPrincipal;
        minAskVolume = x.minAskVolume;
        handler = x.handler.share();
        decimals = x.decimals;
        symbol = x.symbol;
      },
    );
    auctionDataV7 := auction.share();
    ptData := metrics.share();
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

  // A timer for running auction
  ignore (
    func() : async () {
      ignore Timer.recurringTimer<system>(#seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS)), runAuction);
      await runAuction();
    }
  ) |> Timer.setTimer<system>(#seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000) % AUCTION_INTERVAL_SECONDS)), _);

  // If assets are empty, register quote asset
  if (Vec.size(assets) == 0) {
    ignore Timer.setTimer<system>(
      #seconds(0),
      func() : async () {
        ignore await* registerAsset_(quoteLedgerPrincipal, 0);
      },
    );
  };

};
