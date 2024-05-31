import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";
import Timer "mo:base/Timer";

import PT "mo:promtracker";
import Vec "mo:vector";

import U "./utils";

module {

  public type AssetId = Nat;
  public type OrderId = Nat;

  public type StableData = {
    counters : (sessions : Nat, orders : Nat);
    assets : Vec.Vector<StableAssetInfo>;
    users : RBTree.Tree<Principal, UserInfo>;
    history : List.List<PriceHistoryItem>;
  };

  public func defaultStableData() : StableData = {
    counters = (0, 0);
    assets = Vec.new();
    users = #leaf;
    history = null;
  };

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };

  public type SharedOrder = {
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };

  public type UserInfo = {
    var currentAsks : AssocList.AssocList<OrderId, Order>;
    var currentBids : AssocList.AssocList<OrderId, Order>;
    var credits : AssocList.AssocList<AssetId, Account>;
    var history : List.List<TransactionHistoryItem>;
  };

  public type StableAssetInfo = {
    asks : AssocList.AssocList<OrderId, Order>;
    bids : AssocList.AssocList<OrderId, Order>;
    lastSwapRate : Float;
  };

  public type AssetInfo = {
    var asks : AssocList.AssocList<OrderId, Order>;
    var bids : AssocList.AssocList<OrderId, Order>;
    var lastSwapRate : Float;
    metrics : {
      bidsAmount : PT.CounterValue;
      totalBidVolume : PT.CounterValue;
      asksAmount : PT.CounterValue;
      totalAskVolume : PT.CounterValue;
      lastProcessingInstructions : PT.CounterValue;
    };
  };

  public type CancelOrderError = { #UnknownPrincipal };
  public type PlaceOrderError = {
    #ConflictingOrder : OrderId;
    #NoCredit;
    #TooLowOrder;
    #UnknownPrincipal;
    #UnknownAsset;
  };
  public type ReplaceOrderError = {
    #ConflictingOrder : OrderId;
    #NoCredit;
    #TooLowOrder;
    #UnknownOrder;
    #UnknownPrincipal;
  };

  // when spent instructions on bids processing exceeds this value, we stop iterating over assets and commit processed ones.
  // Canister will continue processing them on next heartbeat
  let BID_PROCESSING_INSTRUCTIONS_THRESHOLD : Nat64 = 1_000_000_000;
  // minimum price*volume for placing a bid or an ask. Assuming that trusted token is ICP with 8 decimals,
  // it gives 0.005 ICP: For ICP price $20 it is $0.10
  let MINIMUM_ORDER = 500_000;

  public func getTotalPrice(volume : Nat, unitPrice : Float) : Nat = Int.abs(Float.toInt(Float.ceil(unitPrice * Float.fromInt(volume))));

  // internal usage only
  type OrderCtx = {
    assetList : (assetInfo : AssetInfo) -> AssocList.AssocList<OrderId, Order>;
    assetListSet : (assetInfo : AssetInfo, list : AssocList.AssocList<OrderId, Order>) -> ();

    userList : (userInfo : UserInfo) -> AssocList.AssocList<OrderId, Order>;
    userListSet : (userInfo : UserInfo, list : AssocList.AssocList<OrderId, Order>) -> ();
    userOppositeList : (userInfo : UserInfo) -> AssocList.AssocList<OrderId, Order>;
    oppositeOrderConflictCriteria : (orderPrice : Float, oppositeOrderPrice : Float) -> Bool;

    chargeToken : (orderAssetId : AssetId) -> AssetId;
    chargeAmount : (volume : Nat, price : Float) -> Nat;
    priorityComparator : (order : Order, newOrder : Order) -> Bool;
    lowOrderSign : (orderAssetId : AssetId, orderAssetInfo : AssetInfo, volume : Nat, price : Float) -> Bool;

    amountMetric : (assetInfo : AssetInfo) -> PT.CounterValue;
    volumeMetric : (assetInfo : AssetInfo) -> PT.CounterValue;
  };

  public class Auction<system>(
    trustedAssetId : AssetId,
    metrics : PT.PromTracker,
    settings : {
      minAskVolume : (AssetId, AssetInfo) -> Int;
    },
    hooks : {
      preAuction : ?(() -> async* ());
      postAuction : ?(() -> async* ());
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;
    // a counter of ever added order
    public var ordersCounter = 0;
    // asset info, index == assetId
    public var assets : Vec.Vector<AssetInfo> = Vec.new();
    // user info
    public let users : RBTree.RBTree<Principal, UserInfo> = RBTree.RBTree<Principal, UserInfo>(Principal.compare);
    // asset history
    public var history : List.List<PriceHistoryItem> = null;

    metrics.addSystemValues();
    ignore metrics.addPullValue("sessions_counter", "", func() = sessionsCounter);
    ignore metrics.addPullValue("assets_amount", "", func() = Vec.size(assets));
    let metricUsersAmount = metrics.addCounter("users_amount", "", true);
    let metricAccountsAmount = metrics.addCounter("accounts_amount", "", true);
    public func initAssetMetrics(assetId : AssetId) : {
      asksAmount : PT.CounterValue;
      totalAskVolume : PT.CounterValue;
      bidsAmount : PT.CounterValue;
      totalBidVolume : PT.CounterValue;
      lastProcessingInstructions : PT.CounterValue;
    } = {
      asksAmount = metrics.addCounter("asks_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      totalAskVolume = metrics.addCounter("asks_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      bidsAmount = metrics.addCounter("bids_amount", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      totalBidVolume = metrics.addCounter("bids_volume", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
      lastProcessingInstructions = metrics.addCounter("processing_instructions", "asset_id=\"" # Nat.toText(assetId) # "\"", true);
    };

    public func initUser(p : Principal) : UserInfo {
      let data : UserInfo = {
        var currentAsks = null;
        var currentBids = null;
        var credits = null;
        var history = null;
      };
      let oldValue = users.replace(p, data);
      switch (oldValue) {
        case (?v) Prim.trap("Prevented user data overwrite");
        case (_) {};
      };
      metricUsersAmount.add(1);
      data;
    };

    public func registerAssets(n : Nat) {
      var assetsVecSize = Vec.size(assets);
      let newAmount = assetsVecSize + n;
      while (assetsVecSize < newAmount) {
        (
          {
            var asks = List.nil();
            var askCounter = 0;
            var bids = List.nil();
            var bidCounter = 0;
            var lastSwapRate = 0;
            metrics = initAssetMetrics(assetsVecSize);
          } : AssetInfo
        )
        |> Vec.add(assets, _);
        assetsVecSize += 1;
      };
    };

    public func queryCredit(p : Principal, assetId : AssetId) : Nat = users.get(p)
    |> Option.chain<UserInfo, Account>(_, func(info) = AssocList.find(info.credits, assetId, Nat.equal))
    |> Option.map<Account, Nat>(_, func(acc) = acc.credit - acc.lockedCredit)
    |> Option.get(_, 0);

    public func queryCredits(p : Principal) : [(AssetId, Nat)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        let length = List.size(ui.credits);
        var list = ui.credits;
        Array.tabulate<(AssetId, Nat)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?x) (x.0, x.1.credit - x.1.lockedCredit);
            };
          },
        );
      };
    };

    private func queryOrders_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, Order>) : [(OrderId, SharedOrder)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        var list = f(ui);
        let length = List.size(list);
        Array.tabulate<(OrderId, SharedOrder)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?(orderId, order)) (orderId, { order with volume = order.volume });
            };
          },
        );
      };
    };

    public func queryAssetAsks(p : Principal, assetId : AssetId) : [(OrderId, SharedOrder)] = queryOrders_(
      p,
      func(info) = info.currentAsks |> List.filter<(OrderId, Order)>(_, func(_, o) = o.assetId == assetId),
    );
    public func queryAssetBids(p : Principal, assetId : AssetId) : [(OrderId, SharedOrder)] = queryOrders_(
      p,
      func(info) = info.currentBids |> List.filter<(OrderId, Order)>(_, func(_, o) = o.assetId == assetId),
    );

    public func queryAsks(p : Principal) : [(OrderId, SharedOrder)] = queryOrders_(p, func(info) = info.currentAsks);
    public func queryBids(p : Principal) : [(OrderId, SharedOrder)] = queryOrders_(p, func(info) = info.currentBids);

    private func sliceList<T>(list : List.List<T>, limit : Nat, skip : Nat) : [T] {
      var tail = list;
      var i = 0;
      while (i < skip) {
        let ?(_, next) = tail else return [];
        tail := next;
        i += 1;
      };
      let ret : Vec.Vector<T> = Vec.new();
      i := 0;
      label l while (i < limit) {
        let ?(item, next) = tail else break l;
        Vec.add(ret, item);
        tail := next;
        i += 1;
      };
      Vec.toArray(ret);
    };

    private func sliceListWithFilter<T>(list : List.List<T>, f : (item : T) -> Bool, limit : Nat, skip : Nat) : [T] {
      var tail = list;
      var i = 0;
      while (i < skip) {
        let ?(item, next) = tail else return [];
        tail := next;
        if (f(item)) {
          i += 1;
        };
      };
      let ret : Vec.Vector<T> = Vec.new();
      i := 0;
      label l while (i < limit) {
        let ?(item, next) = tail else break l;
        if (f(item)) {
          Vec.add(ret, item);
          i += 1;
        };
        tail := next;
      };
      Vec.toArray(ret);
    };

    public func queryTransactionHistory(p : Principal, assetId : ?AssetId, limit : Nat, skip : Nat) : [TransactionHistoryItem] {
      let ?userInfo = users.get(p) else return [];
      switch (assetId) {
        case (?aid) sliceListWithFilter(userInfo.history, func(item : TransactionHistoryItem) : Bool = item.3 == aid, limit, skip);
        case (null) sliceList(userInfo.history, limit, skip);
      };
    };

    public func queryPriceHistory(assetId : ?AssetId, limit : Nat, skip : Nat) : [PriceHistoryItem] {
      switch (assetId) {
        case (?aid) sliceListWithFilter(history, func(item : PriceHistoryItem) : Bool = item.2 == aid, limit, skip);
        case (null) sliceList(history, limit, skip);
      };
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = switch (users.get(p)) {
        case (?info) info;
        case (null) initUser(p);
      };
      switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
        case (?acc) {
          acc.credit += amount;
          acc.credit - acc.lockedCredit;
        };
        case (null) {
          { var credit = amount; var lockedCredit = 0 }
          |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
          |> (userInfo.credits := _.0);
          metricAccountsAmount.add(1);
          amount;
        };
      };
    };

    public func setCredit(p : Principal, assetId : AssetId, credit : Nat) : Nat {
      let userInfo = switch (users.get(p)) {
        case (?info) info;
        case (null) initUser(p);
      };
      switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
        case (?acc) {
          acc.credit := credit;
          acc.credit - acc.lockedCredit;
        };
        case (null) {
          { var credit = credit; var lockedCredit = 0 }
          |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
          |> (userInfo.credits := _.0);
          metricAccountsAmount.add(1);
          credit;
        };
      };
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = AssocList.find(user.credits, assetId, Nat.equal) else return #err(#NoCredit);
      if (creditAcc.credit < amount + creditAcc.lockedCredit) return #err(#NoCredit);
      // charge credit
      creditAcc.credit -= amount;
      #ok(
        creditAcc.credit,
        func() = creditAcc.credit += amount,
      );
    };

    private func getUserTrustedAccount_(userInfo : UserInfo) : ?Account = AssocList.find<AssetId, Account>(userInfo.credits, trustedAssetId, Nat.equal);

    let askCtx : OrderCtx = {
      assetList = func(assetInfo) = assetInfo.asks;
      assetListSet = func(assetInfo, list) { assetInfo.asks := list };
      userList = func(userInfo) = userInfo.currentAsks;
      userListSet = func(userInfo, list) { userInfo.currentAsks := list };
      userOppositeList = func(userInfo) = userInfo.currentBids;
      oppositeOrderConflictCriteria = func(orderPrice, oppositeOrderPrice) = oppositeOrderPrice >= orderPrice;

      chargeToken = func(assetId) = assetId;
      chargeAmount = func(volume, _) = volume;
      priorityComparator = func(order, newOrder) = order.price > newOrder.price;
      lowOrderSign = func(assetId, assetInfo, volume, _) = volume < settings.minAskVolume(assetId, assetInfo);

      amountMetric = func(assetInfo) = assetInfo.metrics.asksAmount;
      volumeMetric = func(assetInfo) = assetInfo.metrics.totalAskVolume;
    };
    let bidCtx : OrderCtx = {
      assetList = func(assetInfo) = assetInfo.bids;
      assetListSet = func(assetInfo, list) { assetInfo.bids := list };
      userList = func(userInfo) = userInfo.currentBids;
      userListSet = func(userInfo, list) { userInfo.currentBids := list };
      userOppositeList = func(userInfo) = userInfo.currentAsks;
      oppositeOrderConflictCriteria = func(orderPrice, oppositeOrderPrice) = oppositeOrderPrice <= orderPrice;

      chargeToken = func(_) = trustedAssetId;
      chargeAmount = getTotalPrice;
      priorityComparator = func(order, newOrder) = order.price < newOrder.price;
      lowOrderSign = func(_, _, volume, price) = getTotalPrice(volume, price) < MINIMUM_ORDER;

      amountMetric = func(assetInfo) = assetInfo.metrics.bidsAmount;
      volumeMetric = func(assetInfo) = assetInfo.metrics.totalBidVolume;
    };

    // order management functions
    private func placeOrderInternal(ctx : OrderCtx, userInfo : UserInfo, accountToCharge : Account, assetInfo : AssetInfo, order : Order) : OrderId {
      let orderId = ordersCounter;
      ordersCounter += 1;
      // update user info
      AssocList.replace<OrderId, Order>(ctx.userList(userInfo), orderId, Nat.equal, ?order) |> ctx.userListSet(userInfo, _.0);
      accountToCharge.lockedCredit += ctx.chargeAmount(order.volume, order.price);
      // update asset info
      U.insertWithPriority<(OrderId, Order)>(
        ctx.assetList(assetInfo),
        (orderId, order),
        func(x) = ctx.priorityComparator(x.1, order),
      )
      |> ctx.assetListSet(assetInfo, _);
      // update metrics
      ctx.amountMetric(assetInfo).add(1);
      ctx.volumeMetric(assetInfo).add(order.volume);
      orderId;
    };

    private func placeOrder(ctx : OrderCtx, p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#UnknownAsset);
      let assetInfo = Vec.get(assets, assetId);
      if (ctx.lowOrderSign(assetId, assetInfo, volume, price)) return #err(#TooLowOrder);
      let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, ctx.chargeToken(assetId), Nat.equal) else return #err(#NoCredit);
      if ((sourceAcc.credit - sourceAcc.lockedCredit) : Nat < ctx.chargeAmount(volume, price)) {
        return #err(#NoCredit);
      };
      for ((oppOrderId, oppOrder) in List.toIter(ctx.userOppositeList(userInfo))) {
        if (oppOrder.assetId == assetId and ctx.oppositeOrderConflictCriteria(price, oppOrder.price)) {
          return #err(#ConflictingOrder(oppOrderId));
        };
      };
      let order : Order = {
        user = p;
        userInfoRef = userInfo;
        assetId = assetId;
        price = price;
        var volume = volume;
      };
      placeOrderInternal(ctx, userInfo, sourceAcc, assetInfo, order) |> #ok(_);
    };

    public func replaceOrder(ctx : OrderCtx, p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      let ?oldOrder = AssocList.find(ctx.userList(userInfo), orderId, Nat.equal) else return #err(#UnknownOrder);

      // validate new order
      if (ctx.lowOrderSign(oldOrder.assetId, Vec.get(assets, oldOrder.assetId), volume, price)) return #err(#TooLowOrder);
      let oldPrice = ctx.chargeAmount(oldOrder.volume, oldOrder.price);
      let newPrice = ctx.chargeAmount(volume, price);

      if (newPrice > oldPrice) {
        let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, ctx.chargeToken(oldOrder.assetId), Nat.equal) else return #err(#NoCredit);
        if ((sourceAcc.credit - sourceAcc.lockedCredit) : Nat + oldPrice < newPrice) {
          return #err(#NoCredit);
        };
      };
      for ((oppOrderId, oppOrder) in List.toIter(ctx.userOppositeList(userInfo))) {
        if (oppOrder.assetId == oldOrder.assetId and ctx.oppositeOrderConflictCriteria(price, oppOrder.price)) {
          return #err(#ConflictingOrder(oppOrderId));
        };
      };
      // actually replace the order
      ignore cancelOrderInternal(ctx, userInfo, orderId);
      placeOrder(ctx, p, oldOrder.assetId, volume, price)
      |> U.requireOk(_)
      |> #ok(_);
    };

    public func cancelOrderInternal(ctx : OrderCtx, userInfo : UserInfo, orderId : OrderId) : ?Order {
      AssocList.replace(ctx.userList(userInfo), orderId, Nat.equal, null)
      |> (
        switch (_) {
          case (_, null) null;
          case (map, ?existingOrder) {
            ctx.userListSet(userInfo, map);
            // return deposit to user
            let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, ctx.chargeToken(existingOrder.assetId), Nat.equal) else Prim.trap("Can never happen");
            sourceAcc.lockedCredit -= ctx.chargeAmount(existingOrder.volume, existingOrder.price);
            // remove ask from asset data
            let assetInfo = Vec.get(assets, existingOrder.assetId);
            let (upd, deleted) = U.listFindOneAndDelete<(OrderId, Order)>(ctx.assetList(assetInfo), func(id, _) = id == orderId);
            assert deleted; // should always be true unless we have a bug with asset orders and user orders out of sync
            ctx.assetListSet(assetInfo, upd);
            ctx.amountMetric(assetInfo).sub(1);
            ctx.volumeMetric(assetInfo).sub(existingOrder.volume);
            ?existingOrder;
          };
        }
      );
    };

    // public shortcuts, optimized by skipping userInfo tree lookup and all validation checks
    public func placeAskInternal(userInfo : UserInfo, askSourceAcc : Account, assetInfo : AssetInfo, order : Order) : OrderId {
      placeOrderInternal(askCtx, userInfo, askSourceAcc, assetInfo, order);
    };

    public func cancelAskInternal(userInfo : UserInfo, orderId : OrderId) : ?Order {
      cancelOrderInternal(askCtx, userInfo, orderId);
    };

    public func placeBidInternal(userInfo : UserInfo, trustedAcc : Account, assetInfo : AssetInfo, order : Order) : OrderId {
      placeOrderInternal(bidCtx, userInfo, trustedAcc, assetInfo, order);
    };

    public func cancelBidInternal(userInfo : UserInfo, orderId : OrderId) : ?Order {
      cancelOrderInternal(bidCtx, userInfo, orderId);
    };

    // public interface
    public func placeAsk(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      placeOrder(askCtx, p, assetId, volume, price);
    };

    public func replaceAsk(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      replaceOrder(askCtx, p, orderId, volume, price);
    };

    public func cancelAsk(p : Principal, orderId : OrderId) : R.Result<Bool, CancelOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      cancelAskInternal(userInfo, orderId) |> #ok(not Option.isNull(_));
    };

    public func placeBid(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      placeOrder(bidCtx, p, assetId, volume, price);
    };

    public func replaceBid(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      replaceOrder(bidCtx, p, orderId, volume, price);
    };

    public func cancelBid(p : Principal, orderId : OrderId) : R.Result<Bool, CancelOrderError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      cancelBidInternal(userInfo, orderId) |> #ok(not Option.isNull(_));
    };

    // total instructions sent on last auction processing routine. Accumulated in case processing was splitted to few heartbeat calls
    public var lastBidProcessingInstructions : Nat64 = 0;
    // amount of chunks, used for processing all assets
    public var lastBidProcessingChunks : Nat8 = 0;

    // loops over asset ids, beginning from provided asset id, processes bids and sends rates to the ledger.
    // stops if we exceed instructions threshold and returns #nextIndex in this case
    private func processAssetsChunk(startIndex : Nat) : async* {
      #done;
      #nextIndex : Nat;
    } {
      let startInstructions = Prim.performanceCounter(0);
      // process bids
      let newSwapRates : Vec.Vector<(AssetId, Float)> = Vec.new();
      Vec.add(newSwapRates, (trustedAssetId, 1.0));
      var nextAssetId = 0;
      let inf : Float = 1 / 0; // +inf
      label l for (assetId in Iter.range(startIndex, Vec.size(assets) - 1)) {
        let assetStartInstructions = Prim.performanceCounter(0);
        nextAssetId := assetId + 1;
        if (assetId == trustedAssetId) continue l;
        let assetInfo = Vec.get(assets, assetId);

        var a = 0; // number of executed ask orders (at least partially executed)
        let ?(na, _) = assetInfo.asks else {
          history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), history);
          continue l;
        };
        var asksTail = assetInfo.asks;
        var nextAsk = na;

        var b = 0; // number of executed buy orders (at least partially executed)
        let ?(nb, _) = assetInfo.bids else {
          history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), history);
          continue l;
        };
        var bidsTail = assetInfo.bids;
        var nextBid = nb;

        var asksVolume = 0;
        var bidsVolume = 0;

        let (asksAmount, bidsAmount) = label L : (Nat, Nat) loop {
          let orig = (a, b);
          let inc_ask = asksVolume <= bidsVolume;
          let inc_bid = bidsVolume <= asksVolume;
          let prevAsk = nextAsk;
          if (inc_ask) {
            a += 1;
            let ?(na, at) = asksTail else break L orig;
            nextAsk := na;
            asksTail := at;
          };
          if (inc_bid) {
            b += 1;
            let ?(nb, bt) = bidsTail else {
              if (inc_ask) {
                // revert inc_ask, new one will not be fulfilled
                a -= 1;
                nextAsk := prevAsk;
              };
              break L orig;
            };
            nextBid := nb;
            bidsTail := bt;
          };
          if (nextAsk.1.price > nextBid.1.price) break L orig;
          if (inc_ask) asksVolume += nextAsk.1.volume;
          if (inc_bid) bidsVolume += nextBid.1.volume;
        };

        if (asksAmount == 0) {
          // highest bid was lower than lowest ask
          history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), history);
          continue l;
        };
        // Note: asksAmount > 0 implies bidsAmount > 0

        let dealVolume = Nat.min(asksVolume, bidsVolume);

        let price : Float = switch (nextAsk.1.price == 0.0, nextBid.1.price == inf) {
          case (true, true) {
            // market sell against market buy => no execution
            history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), history);
            continue l;
          };
          case (true, _) nextBid.1.price; // market sell against highest bid => use bid price
          case (_, true) nextAsk.1.price; // market buy against lowest ask => use ask price
          case (_) (nextAsk.1.price + nextBid.1.price) / 2; // limit sell against limit buy => use middle price
        };

        // process fulfilled asks
        var i = 0;
        var dealVolumeLeft = dealVolume;
        asksTail := assetInfo.asks;
        label b while (i < asksAmount) {
          let ?((orderId, order), next) = asksTail else Prim.trap("Can never happen: list shorter than before");
          let userInfo = order.userInfoRef;
          // update ask in user info and calculate real ask volume
          let volume = if (i + 1 == asksAmount and dealVolumeLeft != order.volume) {
            order.volume -= dealVolumeLeft;
            dealVolumeLeft;
          } else {
            AssocList.replace<OrderId, Order>(userInfo.currentAsks, orderId, Nat.equal, null) |> (userInfo.currentAsks := _.0);
            asksTail := next;
            assetInfo.metrics.asksAmount.sub(1);
            dealVolumeLeft -= order.volume;
            order.volume;
          };
          // remove price from deposit
          let ?sourceAcc = AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal) else Prim.trap("Can never happen");
          sourceAcc.credit -= volume;
          // unlock locked deposit
          sourceAcc.lockedCredit -= volume;
          // credit user with trusted tokens
          switch (getUserTrustedAccount_(userInfo)) {
            case (?acc) acc.credit += getTotalPrice(volume, price);
            case (null) {
              {
                var credit = getTotalPrice(volume, price);
                var lockedCredit = 0;
              }
              |> AssocList.replace<AssetId, Account>(userInfo.credits, trustedAssetId, Nat.equal, ?_)
              |> (userInfo.credits := _.0);
              metricAccountsAmount.add(1);
            };
          };
          // update metrics
          assetInfo.metrics.totalAskVolume.sub(volume);
          // append to history
          userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
          i += 1;
        };
        assetInfo.asks := asksTail;

        // process fulfilled bids
        i := 0;
        dealVolumeLeft := dealVolume;
        bidsTail := assetInfo.bids;
        label b while (i < bidsAmount) {
          let ?((orderId, order), next) = bidsTail else Prim.trap("Can never happen: list shorter than before");
          let userInfo = order.userInfoRef;
          // update bid in user info and calculate real bid volume
          let volume = if (i + 1 == bidsAmount and dealVolumeLeft != order.volume) {
            order.volume -= dealVolumeLeft;
            dealVolumeLeft;
          } else {
            AssocList.replace<OrderId, Order>(userInfo.currentBids, orderId, Nat.equal, null) |> (userInfo.currentBids := _.0);
            bidsTail := next;
            assetInfo.metrics.bidsAmount.sub(1);
            dealVolumeLeft -= order.volume;
            order.volume;
          };
          // remove price from deposit
          let ?trustedAcc = getUserTrustedAccount_(userInfo) else Prim.trap("Can never happen");
          trustedAcc.credit -= getTotalPrice(volume, price);
          // unlock locked deposit (note that it uses bid price)
          trustedAcc.lockedCredit -= getTotalPrice(volume, order.price);
          // credit user with tokens
          switch (AssocList.find<AssetId, Account>(userInfo.credits, assetId, Nat.equal)) {
            case (?acc) acc.credit += volume;
            case (null) {
              { var credit = volume; var lockedCredit = 0 }
              |> AssocList.replace<AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?_)
              |> (userInfo.credits := _.0);
              metricAccountsAmount.add(1);
            };
          };
          // update metrics
          assetInfo.metrics.totalBidVolume.sub(volume);
          // append to history
          userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
          i += 1;
        };
        assetInfo.bids := bidsTail;

        assetInfo.lastSwapRate := price;
        // append to asset history
        history := List.push((Prim.time(), sessionsCounter, assetId, dealVolume, price), history);

        let curPerfCounter = Prim.performanceCounter(0);
        assetInfo.metrics.lastProcessingInstructions.set(Nat64.toNat(curPerfCounter - assetStartInstructions));
        if (curPerfCounter - startInstructions > BID_PROCESSING_INSTRUCTIONS_THRESHOLD) break l;
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

    var nextAssetIdToProcess : Nat = 0;

    public func onTimer() : async () {
      if (nextAssetIdToProcess == 0) {
        switch (hooks.preAuction) {
          case (?hook) await* hook();
          case (_) {};
        };
      };
      switch (await* processAssetsChunk(nextAssetIdToProcess)) {
        case (#done) {
          switch (hooks.postAuction) {
            case (?hook) await* hook();
            case (_) {};
          };
          sessionsCounter += 1;
          nextAssetIdToProcess := 0;
        };
        case (#nextIndex next) {
          if (next == nextAssetIdToProcess) {
            Prim.trap("Can never happen: not a single asset processed");
          };
          nextAssetIdToProcess := next;
          ignore Timer.setTimer<system>(#seconds(1), onTimer);
        };
      };
    };

    let AUCTION_INTERVAL_SECONDS : Nat64 = 86_400; // a day
    public func remainingTime() : Nat = Nat64.toNat(AUCTION_INTERVAL_SECONDS - (Prim.time() / 1_000_000_000) % AUCTION_INTERVAL_SECONDS);

    // run daily at 12:00 a.m. UTC
    ignore (
      func() : async () {
        ignore Timer.recurringTimer<system>(#seconds(Nat64.toNat(AUCTION_INTERVAL_SECONDS)), onTimer);
        await onTimer();
      }
    ) |> Timer.setTimer<system>(#seconds(remainingTime()), _);

    public func share() : StableData = {
      counters = (sessionsCounter, ordersCounter);
      assets = Vec.map<AssetInfo, StableAssetInfo>(
        assets,
        func(x) = {
          asks = x.asks;
          bids = x.bids;
          lastSwapRate = x.lastSwapRate;
        },
      );
      users = users.share();
      history = history;
    };

    public func unshare(data : StableData) {
      sessionsCounter := data.counters.0;
      ordersCounter := data.counters.1;
      var i = 0;
      assets := Vec.map<StableAssetInfo, AssetInfo>(
        data.assets,
        func(x) {
          let r = {
            var asks = x.asks;
            var bids = x.bids;
            var lastSwapRate = x.lastSwapRate;
            metrics = initAssetMetrics(i);
          };
          i += 1;
          r;
        },
      );
      users.unshare(data.users);
      history := data.history;
    };

  };
};
