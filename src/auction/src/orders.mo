import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:core/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Prim "mo:prim";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import Assets "./assets";
import C "./constants";
import Credits "./credits";
import Users "./users";

import T "./types";
import AssetOrderBook "asset_order_book";
import PriorityQueue "priority_queue";

module {

  public type CancellationAction = {
    #all : ?[T.AssetId];
    #orders : [{ #ask : T.OrderId; #bid : T.OrderId }];
  };

  public type PlaceOrderAction = {
    #ask : (assetId : T.AssetId, orderBookType : T.OrderBookType, volume : Nat, price : Float);
    #bid : (assetId : T.AssetId, orderBookType : T.OrderBookType, volume : Nat, price : Float);
  };

  public type CancellationResult = (T.OrderId, assetId : T.AssetId, orderBookType : T.OrderBookType, volume : Nat, price : Float);
  public type PlaceOrderResult = (T.OrderId, { #placed; #executed : [(price : Float, volume : Nat)] });

  public type InternalCancelOrderError = {
    #UnknownOrder;
  };
  public type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?T.OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
    #PriceDigitsOverflow : { maxDigits : Nat };
    #VolumeStepViolated : { baseVolumeStep : Nat };
  };

  public type OrderManagementError = {
    #AccountRevisionMismatch;
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

  /// helper class to work with all orders of given asset
  public class OrderBookExecutionService(
    service : OrdersService,
    assetInfo : T.AssetInfo,
    orderBookType : {
      #immediate;
      #combined : { encryptedOrdersQueue : List.List<T.Order> };
    },
  ) {

    public func toIter() : Iter.Iter<(?T.OrderId, T.Order)> {
      switch (orderBookType) {
        // Note: for immediate order book we always take only the first entry, because clearing happens for each ask-bid pair separately
        case (#immediate) {
          service.assetOrderBook(assetInfo, #immediate).queue
          |> List.toIter(_)
          |> Iter.take(_, 1)
          |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o));
        };
        case (#combined { encryptedOrdersQueue }) {

          var delayedCursor = service.assetOrderBook(assetInfo, #delayed).queue;
          var immediateCursor = service.assetOrderBook(assetInfo, #immediate).queue;
          var encryptedCursor = encryptedOrdersQueue;

          object {
            public func next() : ?(?T.OrderId, T.Order) {
              var pickFrom : {
                #delayed : (T.OrderId, T.Order);
                #immediate : (T.OrderId, T.Order);
                #encrypted : T.Order;
                #none;
              } = #none;
              switch (delayedCursor, immediateCursor) {
                case (?(d, _), ?(i, _)) switch (AssetOrderBook.comparePriority(service.kind)(d, i)) {
                  case (#less) pickFrom := #immediate(i);
                  case (_) pickFrom := #delayed(d);
                };
                case (?(item, _), null) pickFrom := #delayed(item);
                case (null, ?(item, _)) pickFrom := #immediate(item);
                case (_) {};
              };
              switch (encryptedCursor, pickFrom) {
                case (?(order, _), #none) pickFrom := #encrypted(order);
                case (?(order, _), #delayed x or #immediate x) switch (AssetOrderBook.comparePriority(service.kind)((0, order), x)) {
                  case (#less) {};
                  case (_) pickFrom := #encrypted(order);
                };
                case (_) {};
              };
              switch (pickFrom) {
                case (#immediate(oid, order)) {
                  let ?c = immediateCursor else Prim.trap("");
                  immediateCursor := c.1;
                  ?(?oid, order);
                };
                case (#delayed(oid, order)) {
                  let ?c = delayedCursor else Prim.trap("");
                  delayedCursor := c.1;
                  ?(?oid, order);
                };
                case (#encrypted(order)) {
                  let ?c = encryptedCursor else Prim.trap("");
                  encryptedCursor := c.1;
                  ?(null, order);
                };
                case (#none) null;
              };
            };
          };
        };
      };
    };

    public func nextOrder() : ?(?T.OrderId, T.Order) = toIter().next();

    public func fulfilOrder(sessionNumber : Nat, orderId : ?T.OrderId, order : T.Order, maxVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat) {
      service.fulfil(assetInfo, sessionNumber, orderId, order, maxVolume, price);
    };

    public func totalVolume() : Nat = service.assetOrderBook(assetInfo, #delayed).totalVolume + service.assetOrderBook(assetInfo, #immediate).totalVolume;
  };

  /// A class with functionality to operate on all orders of the given type across the auction
  class OrdersService(
    assets : Assets.Assets,
    credits : Credits.Credits,
    users : Users.Users,
    quoteAssetId : T.AssetId,
    minQuoteVolume : Nat,
    minAskVolume : (T.AssetId, T.AssetInfo) -> Int,
    kind_ : { #ask; #bid },
  ) = self {

    public func createOrderBookExecutionService(
      assetInfo : T.AssetInfo,
      orderBookType : {
        #immediate;
        #combined : { encryptedOrdersQueue : List.List<T.Order> };
      },
    ) : OrderBookExecutionService = OrderBookExecutionService(self, assetInfo, orderBookType);

    public let kind : { #ask; #bid } = kind_;

    func denominateVolumeInQuoteAsset(volume : Nat, unitPrice : Float) : Nat = unitPrice * Float.fromInt(volume)
    |> (switch (kind) { case (#ask) Float.floor(_); case (#bid) Float.ceil(_) })
    |> Int.abs(Float.toInt(_));

    // returns asset id, which will be debited from user upon placing order
    public func srcAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) orderAssetId;
      case (#bid) quoteAssetId;
    };

    // returns amount to debit from "srcAssetId" account
    public func srcVolume(volume : Nat, price : Float) : Nat = switch (kind) {
      case (#ask) volume;
      case (#bid) denominateVolumeInQuoteAsset(volume, price);
    };

    // returns asset id, which will be credited to user when fulfilling order
    public func destAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) quoteAssetId;
      case (#bid) orderAssetId;
    };

    // returns amount to credit to "destAssetId" account
    public func destVolume(volume : Nat, price : Float) : Nat = switch (kind) {
      case (#ask) denominateVolumeInQuoteAsset(volume, price);
      case (#bid) volume;
    };

    // validation
    public func isOrderLow(orderAssetId : T.AssetId, orderAssetInfo : T.AssetInfo, volume : Nat, price : Float) : Bool = switch (kind) {
      case (#ask) price <= 0.0 or volume < minAskVolume(orderAssetId, orderAssetInfo);
      case (#bid) denominateVolumeInQuoteAsset(volume, price) < minQuoteVolume;
    };

    public func isOppositeOrderConflicts(orderPrice : Float, oppositeOrderPrice : Float) : Bool = switch (kind) {
      case (#ask) oppositeOrderPrice >= orderPrice;
      case (#bid) oppositeOrderPrice <= orderPrice;
    };

    public func assetOrderBook(assetInfo : T.AssetInfo, orderBookType : T.OrderBookType) : T.AssetOrderBook = assets.getOrderBook(assetInfo, kind, orderBookType);

    public func place(userInfo : T.UserInfo, accountToCharge : T.Account, assetInfo : T.AssetInfo, orderId : T.OrderId, order : T.Order) : Nat {
      // charge user credits
      let (success, _) = credits.lockCredit(accountToCharge, srcVolume(order.volume, order.price));
      assert success;
      // insert into order lists
      users.putOrder(userInfo, kind, orderId, order);
      assets.putOrder(assetInfo, kind, orderId, order);
    };

    public func cancel(userInfo : T.UserInfo, orderId : T.OrderId) : ?T.Order {
      // find and remove from order lists
      let ?existingOrder = users.deleteOrder(userInfo, kind, orderId) else return null;
      assets.getAsset(existingOrder.assetId) |> assets.deleteOrder(_, kind, existingOrder.orderBookType, orderId);
      // return deposit to user
      let ?sourceAcc = credits.getAccount(userInfo, srcAssetId(existingOrder.assetId)) else Prim.trap("Can never happen");
      let (success, _) = credits.unlockCredit(sourceAcc, srcVolume(existingOrder.volume, existingOrder.price));
      assert success;

      ?existingOrder;
    };

    // bid: source = quote, dest = base
    // ask: source = base, dest = quote
    public func fulfil(assetInfo : T.AssetInfo, sessionNumber : Nat, orderId : ?T.OrderId, order : T.Order, maxVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat) {
      let ?sourceAcc = credits.getAccount(order.userInfoRef, srcAssetId(order.assetId)) else Prim.trap("Can never happen");

      switch (orderId) {
        case (?oid) credits.unlockCredit(sourceAcc, srcVolume(order.volume, order.price)) |> (assert _.0);
        case (null) {};
      };

      let isPartial = maxVolume < order.volume;
      let baseVolume = Nat.min(maxVolume, order.volume); // = executed volume

      // source and destination volumes
      let srcVol = switch (isPartial, kind) {
        case (true, #bid) price * Float.fromInt(baseVolume) |> Float.floor(_) |> Int.abs(Float.toInt(_));
        case (_) srcVolume(baseVolume, price);
      };
      let destVol = destVolume(baseVolume, price);

      // adjust orders
      switch (orderId) {
        case (?oid) {
          if (isPartial) {
            credits.lockCredit(sourceAcc, srcVolume(order.volume - baseVolume, order.price)) |> (assert _.0); // re-lock credit
            assets.deductOrderVolume(assetInfo, kind, order, baseVolume); // shrink order
          } else {
            users.deleteOrder(order.userInfoRef, kind, oid) |> (ignore _); // delete order
            assets.deleteOrder(assetInfo, kind, order.orderBookType, oid); // delete order
          };
        };
        case (null) {};
      };

      // debit at source
      credits.deductCredit(sourceAcc, srcVol) |> (assert _.0);
      ignore credits.deleteIfEmpty(order.userInfoRef, srcAssetId(order.assetId));

      // credit at destination
      let acc = credits.getOrCreate(order.userInfoRef, destAssetId(order.assetId));
      ignore credits.appendCredit(acc, destVol);

      Vec.add(order.userInfoRef.transactionHistory, (Prim.time(), sessionNumber, kind, order.assetId, baseVolume, price));

      let quoteVolume = switch (kind) {
        case (#ask) destVol;
        case (#bid) srcVol;
      };

      if (not isPartial) {
        assetInfo.totalExecutedOrders += 1;
      };

      order.userInfoRef.accountRevision += 1;
      order.userInfoRef.loyaltyPoints += C.LOYALTY_REWARD.ORDER_EXECUTION + quoteVolume / C.LOYALTY_REWARD.ORDER_VOLUME_DIVISOR;
      switch (kind) {
        case (#ask) assetInfo.totalExecutedVolumeQuote += quoteVolume;
        case (#bid) assetInfo.totalExecutedVolumeBase += baseVolume;
      };

      (baseVolume, quoteVolume);
    };
  };

  public class Orders(
    assets : Assets.Assets,
    credits : Credits.Credits,
    users : Users.Users,
    quoteAssetId : T.AssetId,
    settings : {
      volumeStepLog10 : Nat; // 3 will make volume step 1000 (denominated in quote token)
      minVolumeSteps : Nat; // == minVolume / volumeStep
      priceMaxDigits : Nat;
      minAskVolume : (T.AssetId, T.AssetInfo) -> Int;
    },
  ) {

    public let quoteVolumeStep : Nat = 10 ** settings.volumeStepLog10;
    public let minQuoteVolume : Nat = settings.minVolumeSteps * quoteVolumeStep;
    public let priceMaxDigits : Nat = settings.priceMaxDigits;

    public var executeImmediateOrderBooks : ?((assetId : T.AssetId, advantageFor : { #ask; #bid }) -> [(price : Float, volume : Nat)]) = null;

    public func getBaseVolumeStep(price : Float) : Nat {
      let p = price / Float.fromInt(10 ** settings.volumeStepLog10);
      if (p >= 1) return 1;
      let zf = - Float.log(p) / 2.302_585_092_994_045;
      Int.abs(10 ** Float.toInt(zf));
    };

    public func roundPriceDigits(price : Float) : ?Float {
      if (price >= 1) {
        let e1 = Float.log(price) / 2.302_585_092_994_045;
        let e = Float.trunc(e1);
        let m = 10 ** (e + 1 - Prim.intToFloat(priceMaxDigits));
        let n = price / m; // normalized
        let r = Float.nearest(n); // rounded
        if (Float.equalWithin(n, r, 1e-10)) {
          ?(r * m);
        } else {
          null;
        };
      } else {
        let e1 = Float.log(price) / 2.302_585_092_994_047;
        let e = Float.trunc(e1);
        let m = 10 ** (Prim.intToFloat(priceMaxDigits) - e);
        let n = price * m; // normalized
        let r = Float.nearest(n); // rounded
        if (Float.equalWithin(n, r, 1e-10)) {
          ?(r / m);
        } else {
          null;
        };
      };
    };

    // a counter of ever added order
    public var ordersCounter = 0;

    public let asks : OrdersService = OrdersService(
      assets,
      credits,
      users,
      quoteAssetId,
      minQuoteVolume,
      settings.minAskVolume,
      #ask,
    );
    public let bids : OrdersService = OrdersService(
      assets,
      credits,
      users,
      quoteAssetId,
      minQuoteVolume,
      settings.minAskVolume,
      #bid,
    );

    public func manageOrders(
      p : Principal,
      userInfo : T.UserInfo,
      cancellations : ?CancellationAction,
      placements : [PlaceOrderAction],
      expectedAccountRevision : ?Nat,
    ) : R.Result<([CancellationResult], [PlaceOrderResult]), OrderManagementError> {

      switch (expectedAccountRevision) {
        case (?rev) {
          if (rev != userInfo.accountRevision) {
            return #err(#AccountRevisionMismatch);
          };
        };
        case (null) {};
      };

      // temporary list of new balances for all affected user credit accounts
      var newBalances : AssocList.AssocList<T.AssetId, Nat> = null;
      // temporary lists of newly placed/cancelled orders
      type OrdersDelta = {
        var placed : List.List<(?T.OrderId, T.Order)>;
        var isOrderCancelled : (assetId : T.AssetId, orderId : T.OrderId) -> Bool;
      };
      var asksDelta : OrdersDelta = {
        var placed = null;
        var isOrderCancelled = func(_, _) = false;
      };
      var bidsDelta : OrdersDelta = {
        var placed = null;
        var isOrderCancelled = func(_, _) = false;
      };

      // array of functions which will write all changes to the state
      var cancellationCommitActions : List.List<() -> [CancellationResult]> = null;
      let placementCommitActions = Array.init<() -> PlaceOrderResult>(placements.size(), func() = (0, #placed));

      // update temporary balances: add unlocked credits for each cancelled order
      func affectNewBalancesWithCancellation(ordersService : OrdersService, order : T.Order) {
        let srcAssetId = ordersService.srcAssetId(order.assetId);
        let balance = switch (AssocList.find<T.AssetId, Nat>(newBalances, srcAssetId, Nat.equal)) {
          case (?b) b;
          case (null) credits.balance(userInfo, srcAssetId);
        };
        AssocList.replace<T.AssetId, Nat>(
          newBalances,
          srcAssetId,
          Nat.equal,
          ?(balance + ordersService.srcVolume(order.volume, order.price)),
        ) |> (newBalances := _.0);
      };

      // prepare cancellation of all orders by type (ask or bid)
      func prepareBulkCancellation(ordersService : OrdersService) {
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        for ((orderId, order) in List.toIter(userOrderBook.map)) {
          affectNewBalancesWithCancellation(ordersService, order);
        };
        cancellationCommitActions := List.push<() -> [CancellationResult]>(
          func() {
            let ret : Vec.Vector<CancellationResult> = Vec.new();
            label l while (true) {
              switch (userOrderBook.map) {
                case (?((orderId, _), _)) {
                  let ?order = ordersService.cancel(userInfo, orderId) else Prim.trap("Can never happen");
                  Vec.add(ret, (orderId, order.assetId, order.orderBookType, order.volume, order.price));
                };
                case (_) break l;
              };
            };
            Vec.toArray(ret);
          },
          cancellationCommitActions,
        );
      };

      // prepare cancellation of all orders by given filter function by type (ask or bid)
      func prepareBulkCancellationWithFilter(ordersService : OrdersService, isCancel : (assetId : T.AssetId, orderId : T.OrderId) -> Bool) {
        // TODO can be optimized: cancelOrderInternal searches for order by it's id with linear complexity
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        let orderIds : Vec.Vector<T.OrderId> = Vec.new();
        for ((orderId, order) in List.toIter(userOrderBook.map)) {
          if (isCancel(order.assetId, orderId)) {
            affectNewBalancesWithCancellation(ordersService, order);
            Vec.add(orderIds, orderId);
          };
        };
        cancellationCommitActions := List.push<() -> [CancellationResult]>(
          func() {
            let ret : Vec.Vector<CancellationResult> = Vec.new();
            for (orderId in Vec.vals(orderIds)) {
              let ?order = ordersService.cancel(userInfo, orderId) else Prim.trap("Can never happen");
              Vec.add(ret, (orderId, order.assetId, order.orderBookType, order.volume, order.price));
            };
            Vec.toArray(ret);
          },
          cancellationCommitActions,
        );
      };

      switch (cancellations) {
        case (null) {};
        case (?#all(null)) {
          asksDelta.isOrderCancelled := func(_, _) = true;
          bidsDelta.isOrderCancelled := func(_, _) = true;
          prepareBulkCancellation(asks);
          prepareBulkCancellation(bids);
        };
        case (?#all(?aids)) {
          asksDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          prepareBulkCancellationWithFilter(asks, asksDelta.isOrderCancelled);
          prepareBulkCancellationWithFilter(bids, bidsDelta.isOrderCancelled);
        };
        case (?#orders(orders)) {
          let cancelledAsks : RBTree.RBTree<T.OrderId, ()> = RBTree.RBTree(Nat.compare);
          let cancelledBids : RBTree.RBTree<T.OrderId, ()> = RBTree.RBTree(Nat.compare);
          asksDelta.isOrderCancelled := func(_, orderId) = cancelledAsks.get(orderId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(_, orderId) = cancelledBids.get(orderId) |> not Option.isNull(_);

          var assetIdSet : AssocList.AssocList<T.AssetId, Nat> = null;
          for (i in orders.keys()) {
            let (ordersService, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (asks, orderId, cancelledAsks);
              case (#bid orderId) (bids, orderId, cancelledBids);
            };
            let ?oldOrder = users.findOrder(userInfo, ordersService.kind, orderId) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(ordersService, oldOrder);
            cancelledTree.put(orderId, ());
            cancellationCommitActions := List.push<() -> [CancellationResult]>(
              func() {
                let ?order = ordersService.cancel(userInfo, orderId) else return [];
                [(orderId, order.assetId, order.orderBookType, order.volume, order.price)];
              },
              cancellationCommitActions,
            );
            AssocList.replace<T.AssetId, Nat>(assetIdSet, oldOrder.assetId, Nat.equal, ?i) |> (assetIdSet := _.0);
          };
        };
      };

      // validate and prepare placements
      var assetIdSet : AssocList.AssocList<T.AssetId, Nat> = null;
      for (i in placements.keys()) {
        let (ordersService, (assetId, orderBookType, volume, rawPrice), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (asks, args, asksDelta, bidsDelta);
          case (#bid(args)) (bids, args, bidsDelta, asksDelta);
        };
        // validate asset id
        if (assetId == quoteAssetId or assetId >= assets.nAssets()) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume and price
        let assetInfo = assets.getAsset(assetId);
        let ?price = roundPriceDigits(rawPrice) else return #err(#placement({ index = i; error = #PriceDigitsOverflow({ maxDigits = priceMaxDigits }) }));

        if (ordersService.isOrderLow(assetId, assetInfo, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        let baseVolumeStep = getBaseVolumeStep(price);
        if (volume % baseVolumeStep != 0) return #err(#placement({ index = i; error = #VolumeStepViolated({ baseVolumeStep }) }));

        // validate user credit
        let srcAssetId = ordersService.srcAssetId(assetId);
        let chargeAmount = ordersService.srcVolume(volume, price);
        let ?chargeAcc = credits.getAccount(userInfo, srcAssetId) else return #err(#placement({ index = i; error = #NoCredit }));
        let balance = switch (AssocList.find<T.AssetId, Nat>(newBalances, srcAssetId, Nat.equal)) {
          case (?b) b;
          case (null) credits.accountBalance(chargeAcc);
        };
        if (balance < chargeAmount) {
          return #err(#placement({ index = i; error = #NoCredit }));
        };
        AssocList.replace<T.AssetId, Nat>(newBalances, srcAssetId, Nat.equal, ?(balance - chargeAmount))
        |> (newBalances := _.0);

        // build list of placed orders + orders to be placed during this call
        func buildOrdersList(user : T.UserInfo, kind : { #ask; #bid }, delta : OrdersDelta) : Iter.Iter<(?T.OrderId, T.Order)> = users.getOrderBook(user, kind).map
        |> List.toIter(_)
        |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o))
        |> Iter.concat<(?T.OrderId, T.Order)>(_, List.toIter(delta.placed));

        // validate conflicting orders
        for ((orderId, order) in buildOrdersList(userInfo, ordersService.kind, ordersDelta)) {
          if (
            order.assetId == assetId and price == order.price and (
              switch (orderId) {
                case (?oid) not ordersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(ordersService.kind, orderId) }));
          };
        };

        let oppositeOrderManager = switch (ordersService.kind) {
          case (#ask) { bids };
          case (#bid) { asks };
        };
        for ((oppOrderId, oppOrder) in buildOrdersList(userInfo, oppositeOrderManager.kind, oppositeOrdersDelta)) {
          if (
            oppOrder.assetId == assetId and ordersService.isOppositeOrderConflicts(price, oppOrder.price) and (
              switch (oppOrderId) {
                case (?oid) not oppositeOrdersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(oppositeOrderManager.kind, oppOrderId) }));
          };
        };

        let order : T.Order = {
          user = p;
          userInfoRef = userInfo;
          assetId;
          orderBookType;
          price;
          var volume = volume;
        };
        ordersDelta.placed := List.push((null, order), ordersDelta.placed);

        placementCommitActions[i] := func() {
          let orderId = ordersCounter;
          ordersCounter += 1;
          switch (order.orderBookType, ordersService.place(userInfo, chargeAcc, assetInfo, orderId, order)) {
            case (#immediate, 0) {
              let ?executeFunc = executeImmediateOrderBooks else Prim.trap("execute function was not set");
              let executionResults = executeFunc(order.assetId, ordersService.kind);
              if (executionResults.size() > 0) {
                (orderId, #executed(executionResults));
              } else {
                (orderId, #placed);
              };
            };
            case (_) (orderId, #placed);
          };
        };
        AssocList.replace<T.AssetId, Nat>(assetIdSet, assetId, Nat.equal, ?i) |> (assetIdSet := _.0);
      };

      // commit changes, return results
      let retCancellations : Vec.Vector<CancellationResult> = Vec.new();
      for (cancel in List.toIter(cancellationCommitActions)) {
        for (c in cancel().vals()) {
          Vec.add(retCancellations, c);
        };
      };
      let retPlacements = Array.tabulate<PlaceOrderResult>(placementCommitActions.size(), func(i) = placementCommitActions[i]());

      if (Vec.size(retCancellations) > 0 or placements.size() > 0) {
        userInfo.accountRevision += 1;
        userInfo.loyaltyPoints += (Vec.size(retCancellations) + placements.size()) * C.LOYALTY_REWARD.ORDER_MODIFICATION;
      };

      if (placements.size() > 0) {
        let oldRecord = users.participantsArchive.replace(p, { lastOrderPlacement = Prim.time() });
        switch (oldRecord) {
          case (null) users.participantsArchiveSize += 1;
          case (_) {};
        };
      };

      #ok(Vec.toArray(retCancellations), retPlacements);
    };

    public func manageDarkOrderBooks(
      p : Principal,
      userInfo : T.UserInfo,
      placements : [(assetId : T.AssetId, data : ?T.EncryptedOrderBook)],
      expectedAccountRevision : ?Nat,
    ) : R.Result<[?T.EncryptedOrderBook], { #AccountRevisionMismatch; #NoCredit }> {
      let ret = Array.init<?T.EncryptedOrderBook>(placements.size(), null);
      switch (expectedAccountRevision) {
        case (?rev) {
          if (rev != userInfo.accountRevision) {
            return #err(#AccountRevisionMismatch);
          };
        };
        case (null) {};
      };
      let ?quoteAccount = credits.getAccount(userInfo, quoteAssetId) else return #err(#NoCredit);
      var newDarkOrderBooksPlaced : Int = 0;
      for ((assetId, newData) in placements.values()) {
        switch (newData, users.findDarkOrderBook(userInfo, assetId)) {
          case (?_, null) newDarkOrderBooksPlaced += 1;
          case (null, ?_) newDarkOrderBooksPlaced -= 1;
          case (_) {};
        };
      };
      if (newDarkOrderBooksPlaced > 0) {
        let (locked, _) = credits.lockCredit(quoteAccount, Int.abs(newDarkOrderBooksPlaced) * C.DARK_ORDER_BOOK_LOCK_AMOUNT);
        if (not locked) {
          return #err(#NoCredit);
        };
      } else if (newDarkOrderBooksPlaced < 0) {
        ignore credits.unlockCredit(quoteAccount, Int.abs(newDarkOrderBooksPlaced) * C.DARK_ORDER_BOOK_LOCK_AMOUNT);
      };
      for (i in placements.keys()) {
        let (assetId, data) = placements[i];
        let asset = assets.getAsset(assetId);
        ignore assets.putDarkOrderBook(asset, p, data);
        let oldValue = users.putDarkOrderBook(userInfo, assetId, data);
        ret[i] := oldValue;
      };
      #ok(Array.freeze(ret));
    };

    public func processDarkOrderBooks(assetId : T.AssetId, asset : T.AssetInfo) : (asks : List.List<T.Order>, bids : List.List<T.Order>) {
      if (Option.isNull(asset.darkOrderBooks.encrypted)) return (null, null);
      let ?decryptedOrderBooks = asset.darkOrderBooks.decrypted else Prim.trap("Dark order books were not decrypted");
      var asksQueue : List.List<T.Order> = null;
      var bidsQueue : List.List<T.Order> = null;
      label l for ((user, orders) in decryptedOrderBooks.vals()) {
        let ?userInfo = users.get(user) else continue l;
        let ?quoteAccount = credits.getAccount(userInfo, quoteAssetId) else Prim.trap("Can never happen");
        ignore credits.unlockCredit(quoteAccount, C.DARK_ORDER_BOOK_LOCK_AMOUNT);
        // we do not acutally lock funds for encrypted orders, because we should then unlock them for all the encrypted orders, even not fulfilled
        // so we just check that user has enough funds for them
        let baseAccount = credits.getAccount(userInfo, assetId);
        var quoteToLock = 0;
        var baseToLock = 0;
        label il for ({ kind; price; volume } in orders.vals()) {
          let ordersService = (switch (kind) { case (#ask) { asks }; case (#bid) { bids } });
          let order : T.Order = {
            user;
            userInfoRef = userInfo;
            assetId;
            orderBookType = #delayed;
            price;
            var volume = volume;
          };
          let lockVolume = ordersService.srcVolume(order.volume, order.price);
          let lockSuccess = switch (kind) {
            case (#ask) {
              switch (baseAccount) {
                case (null) false;
                case (?ba) {
                  if (baseToLock + lockVolume + ba.lockedCredit <= ba.credit) {
                    baseToLock += lockVolume;
                    true;
                  } else { false };
                };
              };
            };
            case (#bid) {
              if (quoteToLock + lockVolume + quoteAccount.lockedCredit <= quoteAccount.credit) {
                quoteToLock += lockVolume;
                true;
              } else { false };
            };
          };
          if (not lockSuccess) continue il;
          switch (kind) {
            case (#ask) {
              let (queueUpd, _) = PriorityQueue.insert<T.Order>(asksQueue, order, func(a, b) = Float.compare(b.price, a.price));
              asksQueue := queueUpd;
            };
            case (#bid) {
              let (queueUpd, _) = PriorityQueue.insert<T.Order>(bidsQueue, order, func(a, b) = Float.compare(a.price, b.price));
              bidsQueue := queueUpd;
            };
          };
        };
        ignore users.putDarkOrderBook(userInfo, assetId, null);
      };
      asset.darkOrderBooks.encrypted := null;
      asset.darkOrderBooks.decrypted := null;
      (asksQueue, bidsQueue);
    };
  };

};
