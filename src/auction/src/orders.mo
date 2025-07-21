import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import LinkedList "mo:base/List";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Prim "mo:prim";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import List "mo:core/List";

import Assets "./assets";
import C "./constants";
import Credits "./credits";
import Users "./users";

import T "./types";

module {

  public type CancellationAction = {
    #all : ?[T.AssetId];
    #orders : [{ #ask : T.OrderId; #bid : T.OrderId }];
  };

  public type PlaceOrderAction = {
    #ask : (assetId : T.AssetId, volume : Nat, price : Float);
    #bid : (assetId : T.AssetId, volume : Nat, price : Float);
  };

  public type CancellationResult = (T.OrderId, assetId : T.AssetId, volume : Nat, price : Float);

  public type InternalCancelOrderError = {
    #UnknownOrder;
  };
  public type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?T.OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
    #PriceDigitsOverflow : { maxDigits : Nat };
    #VolumeStepViolated : { volumeStep : Nat };
  };

  public type OrderManagementError = {
    #SessionNumberMismatch : T.AssetId;
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

  /// helper class to work with orders of given asset
  public class OrderBookService(service : OrdersService, assetInfo : T.AssetInfo) {

    public func queue() : LinkedList.List<(T.OrderId, T.Order)> = service.assetOrdersQueue(assetInfo);

    public func nextOrder() : ?(T.OrderId, T.Order) = switch (queue()) {
      case (?(x, _)) ?x;
      case (_) null;
    };

    public func fulfilOrder(sessionNumber : Nat, orderId : T.OrderId, order : T.Order, maxBaseVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat) {
      service.fulfil(assetInfo, sessionNumber, orderId, order, maxBaseVolume, price);
    };
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

    public func createOrderBookService(assetInfo : T.AssetInfo) : OrderBookService = OrderBookService(self, assetInfo);

    public let kind : { #ask; #bid } = kind_;

    // returns asset id, which will be debited from user upon placing order
    public func srcAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) orderAssetId;
      case (#bid) quoteAssetId;
    };

    // returns asset id, which will be credited to user when fulfilling order
    public func destAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) quoteAssetId;
      case (#bid) orderAssetId;
    };

    // validation
    public func isOrderLow(orderAssetId : T.AssetId, orderAssetInfo : T.AssetInfo, volume : Nat, price : Float) : Bool = switch (kind) {
      case (#ask) price <= 0.0 or volume < minAskVolume(orderAssetId, orderAssetInfo);
      case (#bid) volume < minQuoteVolume;
    };

    public func isOppositeOrderConflicts(orderPrice : Float, oppositeOrderPrice : Float) : Bool = switch (kind) {
      case (#ask) oppositeOrderPrice >= orderPrice;
      case (#bid) oppositeOrderPrice <= orderPrice;
    };

    public func assetOrdersQueue(assetInfo : T.AssetInfo) : LinkedList.List<(T.OrderId, T.Order)> = switch (kind) {
      case (#ask) assetInfo.asks.queue;
      case (#bid) assetInfo.bids.queue;
    };

    public func place(userInfo : T.UserInfo, accountToCharge : T.Account, assetInfo : T.AssetInfo, orderId : T.OrderId, order : T.Order) {
      // charge user credits
      let (success, _) = credits.lockCredit(accountToCharge, order.volume);
      assert success;
      // insert into order lists
      users.putOrder(userInfo, kind, orderId, order);
      assets.putOrder(assetInfo, kind, orderId, order);
      // add rewards
      userInfo.loyaltyPoints += C.LOYALTY_REWARD.ORDER_MODIFICATION;
    };

    public func cancel(userInfo : T.UserInfo, orderId : T.OrderId) : ?T.Order {
      // find and remove from order lists
      let ?existingOrder = users.deleteOrder(userInfo, kind, orderId) else return null;
      assets.getAsset(existingOrder.assetId) |> assets.deleteOrder(_, kind, orderId);
      // return deposit to user
      let ?sourceAcc = credits.getAccount(userInfo, srcAssetId(existingOrder.assetId)) else Prim.trap("Can never happen");
      let (success, _) = credits.unlockCredit(sourceAcc, existingOrder.volume);
      assert success;
      // add rewards
      userInfo.loyaltyPoints += C.LOYALTY_REWARD.ORDER_MODIFICATION;

      ?existingOrder;
    };

    // bid: source = quote, dest = base
    // ask: source = base, dest = quote
    public func fulfil(assetInfo : T.AssetInfo, sessionNumber : Nat, orderId : T.OrderId, order : T.Order, maxBaseVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat) {
      let ?sourceAcc = credits.getAccount(order.userInfoRef, srcAssetId(order.assetId)) else Prim.trap("Can never happen");

      credits.unlockCredit(sourceAcc, order.volume) |> (assert _.0);

      let orderBaseVolume = switch (kind) {
        case (#bid) Float.fromInt(order.volume) / order.price |> Int.abs(Float.toInt(_));
        case (#ask) order.volume;
      };

      let isPartial = maxBaseVolume < orderBaseVolume;

      let baseVolume = Nat.min(maxBaseVolume, orderBaseVolume); // = executed volume
      let quoteVolume = price * Float.fromInt(baseVolume) |> Float.floor(_) |> Int.abs(Float.toInt(_));

      // source and destination volumes
      let (srcVol, destVol) = switch (kind) {
        case (#ask) (baseVolume, quoteVolume);
        case (#bid) (quoteVolume, baseVolume);
      };

      // adjust orders
      if (isPartial) {
        credits.lockCredit(sourceAcc, order.volume - srcVol) |> (assert _.0); // re-lock credit
        assets.deductOrderVolume(assetInfo, kind, order, srcVol); // shrink order
      } else {
        users.deleteOrder(order.userInfoRef, kind, orderId) |> (ignore _); // delete order
        assets.deleteOrder(assetInfo, kind, orderId); // delete order
      };

      // debit at source
      credits.deductCredit(sourceAcc, srcVol) |> (assert _.0);
      ignore credits.deleteIfEmpty(order.userInfoRef, srcAssetId(order.assetId));

      // credit at destination
      let acc = credits.getOrCreate(order.userInfoRef, destAssetId(order.assetId));
      ignore credits.appendCredit(acc, destVol);

      List.add(order.userInfoRef.transactionHistory, (Prim.time(), sessionNumber, kind, order.assetId, baseVolume, price));

      if (not isPartial) {
        assetInfo.totalExecutedOrders += 1;
      };
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
      expectedSessionNumber : ?Nat,
    ) : R.Result<([CancellationResult], [T.OrderId]), OrderManagementError> {

      // temporary list of new balances for all affected user credit accounts
      var newBalances : AssocList.AssocList<T.AssetId, Nat> = null;
      // temporary lists of newly placed/cancelled orders
      type OrdersDelta = {
        var placed : LinkedList.List<(?T.OrderId, T.Order)>;
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
      var cancellationCommitActions : LinkedList.List<() -> [CancellationResult]> = null;
      let placementCommitActions : [var () -> T.OrderId] = Array.init<() -> T.OrderId>(placements.size(), func() = 0);

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
          ?(balance + order.volume),
        ) |> (newBalances := _.0);
      };

      // prepare cancellation of all orders by type (ask or bid)
      func prepareBulkCancellation(ordersService : OrdersService) {
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        for ((orderId, order) in LinkedList.toIter(userOrderBook.map)) {
          affectNewBalancesWithCancellation(ordersService, order);
        };
        cancellationCommitActions := LinkedList.push<() -> [CancellationResult]>(
          func() {
            let ret : List.List<CancellationResult> = List.empty();
            label l while (true) {
              switch (userOrderBook.map) {
                case (?((orderId, _), _)) {
                  let ?order = ordersService.cancel(userInfo, orderId) else Prim.trap("Can never happen");
                  List.add(ret, (orderId, order.assetId, order.volume, order.price));
                };
                case (_) break l;
              };
            };
            List.toArray(ret);
          },
          cancellationCommitActions,
        );
      };

      // prepare cancellation of all orders by given filter function by type (ask or bid)
      func prepareBulkCancellationWithFilter(ordersService : OrdersService, isCancel : (assetId : T.AssetId, orderId : T.OrderId) -> Bool) {
        // TODO can be optimized: cancelOrderInternal searches for order by it's id with linear complexity
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        let orderIds : List.List<T.OrderId> = List.empty();
        for ((orderId, order) in LinkedList.toIter(userOrderBook.map)) {
          if (isCancel(order.assetId, orderId)) {
            affectNewBalancesWithCancellation(ordersService, order);
            List.add(orderIds, orderId);
          };
        };
        cancellationCommitActions := LinkedList.push<() -> [CancellationResult]>(
          func() {
            let ret : List.List<CancellationResult> = List.empty();
            for (orderId in List.values(orderIds)) {
              let ?order = ordersService.cancel(userInfo, orderId) else Prim.trap("Can never happen");
              List.add(ret, (orderId, order.assetId, order.volume, order.price));
            };
            List.toArray(ret);
          },
          cancellationCommitActions,
        );
      };

      switch (cancellations) {
        case (null) {};
        case (?#all(null)) {
          switch (expectedSessionNumber) {
            case (?sn) {
              for ((aid, asset) in List.enumerate(assets.assets)) {
                if (aid != quoteAssetId and asset.sessionsCounter != sn) {
                  return #err(#SessionNumberMismatch(aid));
                };
              };
            };
            case (null) {};
          };
          asksDelta.isOrderCancelled := func(_, _) = true;
          bidsDelta.isOrderCancelled := func(_, _) = true;
          prepareBulkCancellation(asks);
          prepareBulkCancellation(bids);
        };
        case (?#all(?aids)) {
          switch (expectedSessionNumber) {
            case (?sn) {
              for (i in aids.keys()) {
                let aid = aids[i];
                if (List.get(assets.assets, aid).sessionsCounter != sn) {
                  return #err(#SessionNumberMismatch(aid));
                };
              };
            };
            case (null) {};
          };
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
            cancellationCommitActions := LinkedList.push<() -> [CancellationResult]>(
              func() {
                let ?order = ordersService.cancel(userInfo, orderId) else return [];
                [(orderId, order.assetId, order.volume, order.price)];
              },
              cancellationCommitActions,
            );
            AssocList.replace<T.AssetId, Nat>(assetIdSet, oldOrder.assetId, Nat.equal, ?i) |> (assetIdSet := _.0);
          };
          switch (expectedSessionNumber) {
            case (?sn) {
              for ((aid, index) in LinkedList.toIter(assetIdSet)) {
                if (List.get(assets.assets, aid).sessionsCounter != sn) {
                  return #err(#SessionNumberMismatch(aid));
                };
              };
            };
            case (null) {};
          };
        };
      };

      // validate and prepare placements
      var assetIdSet : AssocList.AssocList<T.AssetId, Nat> = null;
      for (i in placements.keys()) {
        let (ordersService, (assetId, volume, rawPrice), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (asks, args, asksDelta, bidsDelta);
          case (#bid(args)) (bids, args, bidsDelta, asksDelta);
        };
        // validate asset id
        if (assetId == quoteAssetId or assetId >= assets.nAssets()) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume and price
        let assetInfo = assets.getAsset(assetId);
        let ?price = roundPriceDigits(rawPrice) else return #err(#placement({ index = i; error = #PriceDigitsOverflow({ maxDigits = priceMaxDigits }) }));

        if (ordersService.isOrderLow(assetId, assetInfo, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        let volumeStep = switch (ordersService.kind) {
          case (#ask) getBaseVolumeStep(price);
          case (#bid) quoteVolumeStep;
        };
        if (volume % volumeStep != 0) return #err(#placement({ index = i; error = #VolumeStepViolated({ volumeStep }) }));

        // validate user credit
        let srcAssetId = ordersService.srcAssetId(assetId);
        let chargeAmount = volume;
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
        |> LinkedList.toIter(_)
        |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o))
        |> Iter.concat<(?T.OrderId, T.Order)>(_, LinkedList.toIter(delta.placed));

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
          assetId = assetId;
          price = price;
          var volume = volume;
        };
        ordersDelta.placed := LinkedList.push((null, order), ordersDelta.placed);

        placementCommitActions[i] := func() {
          let orderId = ordersCounter;
          ordersCounter += 1;
          ordersService.place(userInfo, chargeAcc, assetInfo, orderId, order);
          orderId;
        };
        AssocList.replace<T.AssetId, Nat>(assetIdSet, assetId, Nat.equal, ?i) |> (assetIdSet := _.0);
      };
      switch (expectedSessionNumber) {
        case (?sn) {
          for ((aid, index) in LinkedList.toIter(assetIdSet)) {
            if (List.get(assets.assets, aid).sessionsCounter != sn) {
              return #err(#SessionNumberMismatch(aid));
            };
          };
        };
        case (null) {};
      };

      // commit changes, return results
      let retCancellations : List.List<CancellationResult> = List.empty();
      for (cancel in LinkedList.toIter(cancellationCommitActions)) {
        for (c in cancel().vals()) {
          List.add(retCancellations, c);
        };
      };
      let retPlacements = Array.tabulate<T.OrderId>(placementCommitActions.size(), func(i) = placementCommitActions[i]());

      if (placements.size() > 0) {
        let oldRecord = users.participantsArchive.replace(p, { lastOrderPlacement = Prim.time() });
        switch (oldRecord) {
          case (null) users.participantsArchiveSize += 1;
          case (_) {};
        };
      };

      #ok(List.toArray(retCancellations), retPlacements);
    };
  };

};
