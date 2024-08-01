import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Prim "mo:prim";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import Assets "./assets";
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

  public type InternalCancelOrderError = { #UnknownOrder };
  public type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?T.OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
  };

  public type OrderManagementError = {
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

  public func getTotalPrice(volume : Nat, unitPrice : Float) : Nat = Int.abs(Float.toInt(Float.ceil(unitPrice * Float.fromInt(volume))));

  class OrdersService(
    assets : Assets.Assets,
    credits : Credits.Credits,
    users : Users.Users,
    trustedAssetId : T.AssetId,
    minimumOrder : Nat,
    minAskVolume : (T.AssetId, T.AssetInfo) -> Int,
    kind_ : { #ask; #bid },
  ) {

    public let kind : { #ask; #bid } = kind_;

    // validation
    public func isOrderLow(orderAssetId : T.AssetId, orderAssetInfo : T.AssetInfo, volume : Nat, price : Float) : Bool = switch (kind) {
      case (#ask) volume < minAskVolume(orderAssetId, orderAssetInfo);
      case (#bid) getTotalPrice(volume, price) < minimumOrder;
    };

    public func isOppositeOrderConflicts(orderPrice : Float, oppositeOrderPrice : Float) : Bool = switch (kind) {
      case (#ask) oppositeOrderPrice >= orderPrice;
      case (#bid) oppositeOrderPrice <= orderPrice;
    };

    // returns asset id, which will be charged from user upon placing order
    public func chargeToken(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) orderAssetId;
      case (#bid) trustedAssetId;
    };

    // returns amount to charge from "chargeToken" account
    public func chargeAmount(volume : Nat, price : Float) : Nat = switch (kind) {
      case (#ask) volume;
      case (#bid) getTotalPrice(volume, price);
    };

    public func place(userInfo : T.UserInfo, accountToCharge : T.Account, assetInfo : T.AssetInfo, orderId : T.OrderId, order : T.Order) {
      // charge user credits
      let (success, _) = credits.lockCredit(accountToCharge, chargeAmount(order.volume, order.price));
      assert success;
      // insert into order lists
      users.putOrder(userInfo, kind, orderId, order);
      assets.putOrder(assetInfo, kind, orderId, order);
    };

    public func cancel(userInfo : T.UserInfo, orderId : T.OrderId) : ?T.Order {
      // find and remove from order lists
      let ?existingOrder = users.deleteOrder(userInfo, kind, orderId) else return null;
      assets.getAsset(existingOrder.assetId) |> assets.deleteOrder(_, kind, orderId);
      // return deposit to user
      let ?sourceAcc = credits.getAccount(userInfo, chargeToken(existingOrder.assetId)) else Prim.trap("Can never happen");
      let (success, _) = credits.unlockCredit(sourceAcc, chargeAmount(existingOrder.volume, existingOrder.price));
      assert success;

      ?existingOrder;
    };
  };

  public class Orders(
    assets : Assets.Assets,
    credits : Credits.Credits,
    users : Users.Users,
    trustedAssetId : T.AssetId,
    minimumOrder : Nat,
    minAskVolume : (T.AssetId, T.AssetInfo) -> Int,
  ) {

    // a counter of ever added order
    public var ordersCounter = 0;

    public let asks : OrdersService = OrdersService(
      assets,
      credits,
      users,
      trustedAssetId,
      minimumOrder,
      minAskVolume,
      #ask,
    );
    public let bids : OrdersService = OrdersService(
      assets,
      credits,
      users,
      trustedAssetId,
      minimumOrder,
      minAskVolume,
      #bid,
    );

    public func manageOrders(
      p : Principal,
      userInfo : T.UserInfo,
      cancellations : ?CancellationAction,
      placements : [PlaceOrderAction],
    ) : R.Result<[T.OrderId], OrderManagementError> {

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
      var cancellationCommitActions : List.List<() -> ()> = null;
      let placementCommitActions : [var () -> T.OrderId] = Array.init<() -> T.OrderId>(placements.size(), func() = 0);

      // validate and prepare cancellations

      // update temporary balances: add unlocked credits for each cancelled order
      func affectNewBalancesWithCancellation(ordersService : OrdersService, order : T.Order) {
        let chargeToken = ordersService.chargeToken(order.assetId);
        let balance = switch (AssocList.find<T.AssetId, Nat>(newBalances, chargeToken, Nat.equal)) {
          case (?b) b;
          case (null) credits.balance(userInfo, chargeToken);
        };
        AssocList.replace<T.AssetId, Nat>(
          newBalances,
          chargeToken,
          Nat.equal,
          ?(balance + ordersService.chargeAmount(order.volume, order.price)),
        ) |> (newBalances := _.0);
      };

      // prepare cancellation of all orders by type (ask or bid)
      func prepareBulkCancelation(ordersService : OrdersService) {
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        for ((orderId, order) in List.toIter(userOrderBook.map)) {
          affectNewBalancesWithCancellation(ordersService, order);
        };
        cancellationCommitActions := List.push(
          func() {
            label l while (true) {
              switch (userOrderBook.map) {
                case (?((orderId, _), _)) ignore ordersService.cancel(userInfo, orderId);
                case (_) break l;
              };
            };
          },
          cancellationCommitActions,
        );
      };

      // prepare cancellation of all orders by given filter function by type (ask or bid)
      func prepareBulkCancelationWithFilter(ordersService : OrdersService, isCancel : (assetId : T.AssetId, orderId : T.OrderId) -> Bool) {
        // TODO can be optimized: cancelOrderInternal searches for order by it's id with linear complexity
        let userOrderBook = users.getOrderBook(userInfo, ordersService.kind);
        let orderIds : Vec.Vector<T.OrderId> = Vec.new();
        for ((orderId, order) in List.toIter(userOrderBook.map)) {
          if (isCancel(order.assetId, orderId)) {
            affectNewBalancesWithCancellation(ordersService, order);
            Vec.add(orderIds, orderId);
          };
        };
        cancellationCommitActions := List.push(
          func() {
            for (orderId in Vec.vals(orderIds)) {
              ignore ordersService.cancel(userInfo, orderId);
            };
          },
          cancellationCommitActions,
        );
      };

      switch (cancellations) {
        case (null) {};
        case (? #all(null)) {
          asksDelta.isOrderCancelled := func(_, _) = true;
          bidsDelta.isOrderCancelled := func(_, _) = true;
          prepareBulkCancelation(asks);
          prepareBulkCancelation(bids);
        };
        case (? #all(?aids)) {
          asksDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          prepareBulkCancelationWithFilter(asks, asksDelta.isOrderCancelled);
          prepareBulkCancelationWithFilter(bids, bidsDelta.isOrderCancelled);
        };
        case (? #orders(orders)) {
          let cancelledAsks : RBTree.RBTree<T.OrderId, ()> = RBTree.RBTree(Nat.compare);
          let cancelledBids : RBTree.RBTree<T.OrderId, ()> = RBTree.RBTree(Nat.compare);
          asksDelta.isOrderCancelled := func(_, orderId) = cancelledAsks.get(orderId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(_, orderId) = cancelledBids.get(orderId) |> not Option.isNull(_);

          for (i in orders.keys()) {
            let (ordersService, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (asks, orderId, cancelledAsks);
              case (#bid orderId) (bids, orderId, cancelledBids);
            };
            let ?oldOrder = users.findOrder(userInfo, ordersService.kind, orderId) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(ordersService, oldOrder);
            cancelledTree.put(orderId, ());
            cancellationCommitActions := List.push(
              func() = ignore ordersService.cancel(userInfo, orderId),
              cancellationCommitActions,
            );
          };
        };
      };

      // validate and prepare placements
      for (i in placements.keys()) {
        let (ordersService, (assetId, volume, price), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (asks, args, asksDelta, bidsDelta);
          case (#bid(args)) (bids, args, bidsDelta, asksDelta);
        };

        // validate asset id
        if (assetId == trustedAssetId or assetId >= assets.nAssets()) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume
        let assetInfo = assets.getAsset(assetId);
        if (ordersService.isOrderLow(assetId, assetInfo, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        // validate user credit
        let chargeToken = ordersService.chargeToken(assetId);
        let chargeAmount = ordersService.chargeAmount(volume, price);
        let ?chargeAcc = credits.getAccount(userInfo, chargeToken) else return #err(#placement({ index = i; error = #NoCredit }));
        let balance = switch (AssocList.find<T.AssetId, Nat>(newBalances, chargeToken, Nat.equal)) {
          case (?b) b;
          case (null) credits.accountBalance(chargeAcc);
        };
        if (balance < chargeAmount) {
          return #err(#placement({ index = i; error = #NoCredit }));
        };
        AssocList.replace<T.AssetId, Nat>(newBalances, chargeToken, Nat.equal, ?(balance - chargeAmount))
        |> (newBalances := _.0);

        // build list of placed orders + orders to be placed during this call
        func buildOrdersList(user : T.UserInfo, kind : { #ask; #bid }, delta : OrdersDelta) : Iter.Iter<(?T.OrderId, T.Order)> = users.getOrderBook(user, kind).map
        |> List.toIter(_)
        |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o))
        |> iterConcat<(?T.OrderId, T.Order)>(_, List.toIter(delta.placed));

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
        ordersDelta.placed := List.push((null, order), ordersDelta.placed);

        placementCommitActions[i] := func() {
          let orderId = ordersCounter;
          ordersCounter += 1;
          ordersService.place(userInfo, chargeAcc, assetInfo, orderId, order);
          orderId;
        };
      };

      // commit changes, return results
      for (cancel in List.toIter(cancellationCommitActions)) {
        cancel();
      };
      #ok(Array.tabulate<T.OrderId>(placementCommitActions.size(), func(i) = placementCommitActions[i]()));
    };
  };

  /** concat two iterables into one */
  private func iterConcat<T>(a : Iter.Iter<T>, b : Iter.Iter<T>) : Iter.Iter<T> {
    var aEnded : Bool = false;
    object {
      public func next() : ?T {
        if (aEnded) {
          return b.next();
        };
        let nextA = a.next();
        switch (nextA) {
          case (?val) ?val;
          case (null) {
            aEnded := true;
            b.next();
          };
        };
      };
    };
  };

};
