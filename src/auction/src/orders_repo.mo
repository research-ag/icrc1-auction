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

import AssetsRepo "./assets_repo";
import CreditsRepo "./credits_repo";
import UsersRepo "./users_repo";

import T "./types";
import {
  iterConcat;
} "./utils";

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
    assetsRepo : AssetsRepo.AssetsRepo,
    creditsRepo : CreditsRepo.CreditsRepo,
    usersRepo : UsersRepo.UsersRepo,
    trustedAssetId : T.AssetId,
    minimumOrder : Nat,
    minAskVolume : (T.AssetId, T.AssetInfo) -> Int,
    kind_ : { #ask; #bid },
    // TODO maye those are not needed: use assetRepo and usersRepo API
    assetOrderBookFunc_ : (assetInfo : T.AssetInfo) -> T.AssetOrderBook,
    userOrderBookFunc_ : (userInfo : T.UserInfo) -> T.UserOrderBook,
    // priorityComparator : (a : (T.OrderId, T.Order), b : (T.OrderId, T.Order)) -> O.Order,
  ) {

    public let kind : { #ask; #bid } = kind_;
    public let assetOrderBookFunc : (assetInfo : T.AssetInfo) -> T.AssetOrderBook = assetOrderBookFunc_;
    public let userOrderBookFunc : (userInfo : T.UserInfo) -> T.UserOrderBook = userOrderBookFunc_;

    // validation
    public func isOrderLow(orderAssetId : T.AssetId, orderAssetInfo : T.AssetInfo, volume : Nat, price : Float) : Bool = switch (kind) {
      case (#ask) volume == 0 or (price > 0 and volume < minAskVolume(orderAssetId, orderAssetInfo));
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
      let (success, _) = creditsRepo.lockCredit(accountToCharge, chargeAmount(order.volume, order.price));
      assert success;
      // insert into order lists
      usersRepo.putOrder(userInfo, kind, orderId, order);
      assetsRepo.putOrder(assetInfo, kind, orderId, order);
    };

    public func cancel(userInfo : T.UserInfo, orderId : T.OrderId) : ?T.Order {
      // find and remove from order lists
      let ?existingOrder = usersRepo.popOrder(userInfo, kind, orderId) else return null;
      Vec.get(assetsRepo.assets, existingOrder.assetId) |> assetsRepo.popOrder(_, kind, orderId);
      // return deposit to user
      let ?sourceAcc = creditsRepo.getAccount(userInfo, chargeToken(existingOrder.assetId)) else Prim.trap("Can never happen");
      let (success, _) = creditsRepo.unlockCredit(sourceAcc, chargeAmount(existingOrder.volume, existingOrder.price));
      assert success;

      ?existingOrder;
    };
  };

  public class OrdersRepo(
    assetsRepo : AssetsRepo.AssetsRepo,
    creditsRepo : CreditsRepo.CreditsRepo,
    usersRepo : UsersRepo.UsersRepo,
    // TODO double check whether these are needed after finishing refactoring
    trustedAssetId : T.AssetId,
    minimumOrder : Nat,
    minAskVolume : (T.AssetId, T.AssetInfo) -> Int,
  ) {

    // a counter of ever added order
    public var ordersCounter = 0;

    public let asks : OrdersService = OrdersService(
      assetsRepo,
      creditsRepo,
      usersRepo,
      trustedAssetId,
      minimumOrder,
      minAskVolume,
      #ask,
      func(assetInfo) = assetInfo.asks,
      func(userInfo) = userInfo.asks,
    );
    public let bids : OrdersService = OrdersService(
      assetsRepo,
      creditsRepo,
      usersRepo,
      trustedAssetId,
      minimumOrder,
      minAskVolume,
      #bid,
      func(assetInfo) = assetInfo.bids,
      func(userInfo) = userInfo.bids,
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
          case (null) creditsRepo.balance(userInfo, chargeToken);
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
        let userOrderBook = ordersService.userOrderBookFunc(userInfo);
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
        let userOrderBook = ordersService.userOrderBookFunc(userInfo);
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
            let (orderService, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (asks, orderId, cancelledAsks);
              case (#bid orderId) (bids, orderId, cancelledBids);
            };
            let ?oldOrder = AssocList.find(orderService.userOrderBookFunc(userInfo).map, orderId, Nat.equal) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(orderService, oldOrder);
            cancelledTree.put(orderId, ());
            cancellationCommitActions := List.push(
              func() = ignore orderService.cancel(userInfo, orderId),
              cancellationCommitActions,
            );
          };
        };
      };

      // validate and prepare placements
      for (i in placements.keys()) {
        let (orderService, (assetId, volume, price), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (asks, args, asksDelta, bidsDelta);
          case (#bid(args)) (bids, args, bidsDelta, asksDelta);
        };

        // validate asset id
        if (assetId == trustedAssetId or assetId >= Vec.size(assetsRepo.assets)) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume
        let assetInfo = Vec.get(assetsRepo.assets, assetId);
        if (orderService.isOrderLow(assetId, assetInfo, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        // validate user credit
        let chargeToken = orderService.chargeToken(assetId);
        let chargeAmount = orderService.chargeAmount(volume, price);
        let ?chargeAcc = creditsRepo.getAccount(userInfo, chargeToken) else return #err(#placement({ index = i; error = #NoCredit }));
        let balance = switch (AssocList.find<T.AssetId, Nat>(newBalances, chargeToken, Nat.equal)) {
          case (?b) b;
          case (null) creditsRepo.accountBalance(chargeAcc);
        };
        if (balance < chargeAmount) {
          return #err(#placement({ index = i; error = #NoCredit }));
        };
        AssocList.replace<T.AssetId, Nat>(newBalances, chargeToken, Nat.equal, ?(balance - chargeAmount))
        |> (newBalances := _.0);

        // build list of placed orders + orders to be placed during this call
        func buildOrdersList(userList : List.List<(T.OrderId, T.Order)>, delta : OrdersDelta) : Iter.Iter<(?T.OrderId, T.Order)> = userList
        |> List.toIter(_)
        |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o))
        |> iterConcat<(?T.OrderId, T.Order)>(_, List.toIter(delta.placed));

        // validate conflicting orders
        for ((orderId, order) in buildOrdersList(orderService.userOrderBookFunc(userInfo).map, ordersDelta)) {
          if (
            order.assetId == assetId and price == order.price and (
              switch (orderId) {
                case (?oid) not ordersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(orderService.kind, orderId) }));
          };
        };

        let oppositeOrderManager = switch (orderService.kind) {
          case (#ask) { bids };
          case (#bid) { asks };
        };
        for ((oppOrderId, oppOrder) in buildOrdersList(oppositeOrderManager.userOrderBookFunc(userInfo).map, oppositeOrdersDelta)) {
          if (
            oppOrder.assetId == assetId and orderService.isOppositeOrderConflicts(price, oppOrder.price) and (
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
          orderService.place(userInfo, chargeAcc, assetInfo, orderId, order);
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

};
