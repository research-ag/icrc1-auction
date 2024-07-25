import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import O "mo:base/Order";
import Option "mo:base/Option";
import Prim "mo:prim";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

// remove dependency
import CreditsRepo "./credits_repo";

import PriorityQueue "./priority_queue";
import T "./types";
import {
  flipOrder;
  iterConcat;
} "./utils";

module {

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  type Account = CreditsRepo.Account;
  type AssetInfo = {
    var asks : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var bids : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    // TODO should not be here?
    var lastRate : Float;
  };
  type UserInfo = {
    var credits : AssocList.AssocList<T.AssetId, Account>;
    var currentAsks : AssocList.AssocList<OrderId, Order>;
    var currentBids : AssocList.AssocList<OrderId, Order>;
    // TODO should not be here?
    var history : List.List<(timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float)>;
  };

  public type CancellationAction = {
    #all : ?[AssetId];
    #orders : [{ #ask : OrderId; #bid : OrderId }];
  };

  public type PlaceOrderAction = {
    #ask : (assetId : AssetId, volume : Nat, price : Float);
    #bid : (assetId : AssetId, volume : Nat, price : Float);
  };

  public type InternalCancelOrderError = { #UnknownOrder };
  public type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
  };

  public type OrderManagementError = {
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };

  // internal usage only
  // TODO maybe remove that
  public type OrderCtx = {
    assetList : (assetInfo : AssetInfo) -> AssocList.AssocList<OrderId, Order>;
    assetListSet : (assetInfo : AssetInfo, list : AssocList.AssocList<OrderId, Order>) -> ();

    kind : { #ask; #bid };
    userList : (userInfo : UserInfo) -> AssocList.AssocList<OrderId, Order>;
    userListSet : (userInfo : UserInfo, list : AssocList.AssocList<OrderId, Order>) -> ();

    oppositeKind : { #ask; #bid };
    userOppositeList : (userInfo : UserInfo) -> AssocList.AssocList<OrderId, Order>;
    oppositeOrderConflictCriteria : (orderPrice : Float, oppositeOrderPrice : Float) -> Bool;

    chargeToken : (orderAssetId : AssetId) -> AssetId;
    chargeAmount : (volume : Nat, price : Float) -> Nat;
    priorityComparator : (a : (OrderId, Order), b : (OrderId, Order)) -> O.Order;
    lowOrderSign : (orderAssetId : AssetId, orderAssetInfo : AssetInfo, volume : Nat, price : Float) -> Bool;

    amountStat : (assetId : AssetId) -> {
      add : (n : Nat) -> ();
      sub : (n : Nat) -> ();
    };
    volumeStat : (assetId : AssetId) -> {
      add : (n : Nat) -> ();
      sub : (n : Nat) -> ();
    };
  };

  func orderPriorityComparator(a : (OrderId, Order), b : (OrderId, Order)) : O.Order = Float.compare(a.1.price, b.1.price);
  // TODO copy-pasted function
  public func getTotalPrice(volume : Nat, unitPrice : Float) : Nat = Int.abs(Float.toInt(Float.ceil(unitPrice * Float.fromInt(volume))));

  public class OrdersRepo(
    // TODO double check whether these are needed after finishing refactoring
    trustedAssetId : AssetId,
    minimumOrder : Nat,
    minAskVolume : (AssetId, AssetInfo) -> Int,
    stats : {
      var usersAmount : Nat;
      var accountsAmount : Nat;
      var assets : Vec.Vector<{ var bidsAmount : Nat; var totalBidVolume : Nat; var asksAmount : Nat; var totalAskVolume : Nat; var lastProcessingInstructions : Nat }>;
    },
    assetInfoFunc : (AssetId) -> AssetInfo,
    assetsSizeFunc : () -> Nat,
  ) {

    // a counter of ever added order
    public var ordersCounter = 0;

    public func manageOrders(
      p : Principal,
      userInfo : UserInfo,
      cancellations : ?CancellationAction,
      placements : [PlaceOrderAction],
    ) : R.Result<[OrderId], OrderManagementError> {

      // temporary list of new balances for all affected user credit accounts
      var newBalances : AssocList.AssocList<AssetId, Nat> = null;
      // temporary lists of newly placed/cancelled orders
      type OrdersDelta = {
        var placed : List.List<(?OrderId, Order)>;
        var isOrderCancelled : (assetId : AssetId, orderId : OrderId) -> Bool;
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
      let placementCommitActions : [var () -> OrderId] = Array.init<() -> OrderId>(placements.size(), func() = 0);

      // validate and prepare cancellations

      // update temporary balances: add unlocked credits for each cancelled order
      func affectNewBalancesWithCancellation(ctx : OrderCtx, order : Order) {
        let chargeToken = ctx.chargeToken(order.assetId);
        let balance = switch (AssocList.find<AssetId, Nat>(newBalances, chargeToken, Nat.equal)) {
          case (?b) b;
          case (null) {
            let ?chargeAcc = CreditsRepo.getAccount(userInfo, chargeToken) else Prim.trap("Can never happen");
            CreditsRepo.availableBalance(chargeAcc);
          };
        };
        AssocList.replace<AssetId, Nat>(
          newBalances,
          chargeToken,
          Nat.equal,
          ?(balance + ctx.chargeAmount(order.volume, order.price)),
        ) |> (newBalances := _.0);
      };

      // prepare cancellation of all orders by type (ask or bid)
      func prepareBulkCancelation(ctx : OrderCtx) {
        for ((orderId, order) in List.toIter(ctx.userList(userInfo))) {
          affectNewBalancesWithCancellation(ctx, order);
        };
        cancellationCommitActions := List.push(
          func() {
            label l while (true) {
              switch (ctx.userList(userInfo)) {
                case (?((orderId, _), _)) ignore cancelOrderInternal(ctx, userInfo, orderId);
                case (_) break l;
              };
            };
          },
          cancellationCommitActions,
        );
      };

      // prepare cancellation of all orders by given filter function by type (ask or bid)
      func prepareBulkCancelationWithFilter(ctx : OrderCtx, isCancel : (assetId : AssetId, orderId : OrderId) -> Bool) {
        // TODO can be optimized: cancelOrderInternal searches for order by it's id with linear complexity
        let orderIds : Vec.Vector<OrderId> = Vec.new();
        for ((orderId, order) in List.toIter(ctx.userList(userInfo))) {
          if (isCancel(order.assetId, orderId)) {
            affectNewBalancesWithCancellation(ctx, order);
            Vec.add(orderIds, orderId);
          };
        };
        cancellationCommitActions := List.push(
          func() {
            for (orderId in Vec.vals(orderIds)) {
              ignore cancelOrderInternal(ctx, userInfo, orderId);
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
          prepareBulkCancelation(askCtx);
          prepareBulkCancelation(bidCtx);
        };
        case (? #all(?aids)) {
          asksDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          prepareBulkCancelationWithFilter(askCtx, asksDelta.isOrderCancelled);
          prepareBulkCancelationWithFilter(bidCtx, bidsDelta.isOrderCancelled);
        };
        case (? #orders(orders)) {
          let cancelledAsks : RBTree.RBTree<OrderId, ()> = RBTree.RBTree(Nat.compare);
          let cancelledBids : RBTree.RBTree<OrderId, ()> = RBTree.RBTree(Nat.compare);
          asksDelta.isOrderCancelled := func(_, orderId) = cancelledAsks.get(orderId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(_, orderId) = cancelledBids.get(orderId) |> not Option.isNull(_);

          for (i in orders.keys()) {
            let (ctx, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (askCtx, orderId, cancelledAsks);
              case (#bid orderId) (bidCtx, orderId, cancelledBids);
            };
            let ?oldOrder = AssocList.find(ctx.userList(userInfo), orderId, Nat.equal) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(ctx, oldOrder);
            cancelledTree.put(orderId, ());
            cancellationCommitActions := List.push(
              func() = ignore cancelOrderInternal(ctx, userInfo, orderId),
              cancellationCommitActions,
            );
          };
        };
      };

      // validate and prepare placements
      for (i in placements.keys()) {
        let (ctx, (assetId, volume, price), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (askCtx, args, asksDelta, bidsDelta);
          case (#bid(args)) (bidCtx, args, bidsDelta, asksDelta);
        };

        // validate asset id
        if (assetId == trustedAssetId or assetId >= assetsSizeFunc()) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume
        let assetInfo = assetInfoFunc(assetId);
        if (ctx.lowOrderSign(assetId, assetInfo, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        // validate user credit
        let chargeToken = ctx.chargeToken(assetId);
        let chargeAmount = ctx.chargeAmount(volume, price);
        let ?chargeAcc = CreditsRepo.getAccount(userInfo, chargeToken) else return #err(#placement({ index = i; error = #NoCredit }));
        let balance = switch (AssocList.find<AssetId, Nat>(newBalances, chargeToken, Nat.equal)) {
          case (?b) b;
          case (null) CreditsRepo.availableBalance(chargeAcc);
        };
        if (balance < chargeAmount) {
          return #err(#placement({ index = i; error = #NoCredit }));
        };
        AssocList.replace<AssetId, Nat>(newBalances, chargeToken, Nat.equal, ?(balance - chargeAmount))
        |> (newBalances := _.0);

        // build list of placed orders + orders to be placed during this call
        func buildOrdersList(userList : List.List<(OrderId, Order)>, delta : OrdersDelta) : Iter.Iter<(?OrderId, Order)> = userList
        |> List.toIter(_)
        |> Iter.map<(OrderId, Order), (?OrderId, Order)>(_, func(oid, o) = (?oid, o))
        |> iterConcat<(?OrderId, Order)>(_, List.toIter(delta.placed));

        // validate conflicting orders
        for ((orderId, order) in buildOrdersList(ctx.userList(userInfo), ordersDelta)) {
          if (
            order.assetId == assetId and price == order.price and (
              switch (orderId) {
                case (?oid) not ordersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(ctx.kind, orderId) }));
          };
        };

        for ((oppOrderId, oppOrder) in buildOrdersList(ctx.userOppositeList(userInfo), oppositeOrdersDelta)) {
          if (
            oppOrder.assetId == assetId and ctx.oppositeOrderConflictCriteria(price, oppOrder.price) and (
              switch (oppOrderId) {
                case (?oid) not oppositeOrdersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(ctx.oppositeKind, oppOrderId) }));
          };
        };

        let order : Order = {
          user = p;
          userInfoRef = userInfo;
          assetId = assetId;
          price = price;
          var volume = volume;
        };
        ordersDelta.placed := List.push((null, order), ordersDelta.placed);

        placementCommitActions[i] := func() = placeOrderInternal(ctx, userInfo, chargeAcc, assetId, assetInfo, order);
      };

      // commit changes, return results
      for (cancel in List.toIter(cancellationCommitActions)) {
        cancel();
      };
      #ok(Array.tabulate<OrderId>(placementCommitActions.size(), func(i) = placementCommitActions[i]()));
    };

    // public shortcuts, optimized by skipping userInfo tree lookup and all validation checks
    public func placeAskInternal(userInfo : UserInfo, askSourceAcc : Account, assetId : AssetId, assetInfo : AssetInfo, order : Order) : OrderId {
      placeOrderInternal(askCtx, userInfo, askSourceAcc, assetId, assetInfo, order);
    };

    public func placeBidInternal(userInfo : UserInfo, trustedAcc : Account, assetId : AssetId, assetInfo : AssetInfo, order : Order) : OrderId {
      placeOrderInternal(bidCtx, userInfo, trustedAcc, assetId, assetInfo, order);
    };

    public func cancelAskInternal(userInfo : UserInfo, orderId : OrderId) : ?Order {
      cancelOrderInternal(askCtx, userInfo, orderId);
    };

    public func cancelBidInternal(userInfo : UserInfo, orderId : OrderId) : ?Order {
      cancelOrderInternal(bidCtx, userInfo, orderId);
    };

    public let askCtx : OrderCtx = {
      kind = #ask;
      assetList = func(assetInfo) = assetInfo.asks;
      assetListSet = func(assetInfo, list) { assetInfo.asks := list };
      userList = func(userInfo) = userInfo.currentAsks;
      userListSet = func(userInfo, list) { userInfo.currentAsks := list };

      oppositeKind = #bid;
      userOppositeList = func(userInfo) = userInfo.currentBids;
      oppositeOrderConflictCriteria = func(orderPrice, oppositeOrderPrice) = oppositeOrderPrice >= orderPrice;

      chargeToken = func(assetId) = assetId;
      chargeAmount = func(volume, _) = volume;
      priorityComparator = flipOrder(orderPriorityComparator);
      lowOrderSign = func(assetId, assetInfo, volume, price) = volume == 0 or (price > 0 and volume < minAskVolume(assetId, assetInfo));

      amountStat = func(assetId) = {
        add = func(n : Nat) {
          Vec.get(stats.assets, assetId).asksAmount += n;
        };
        sub = func(n : Nat) {
          Vec.get(stats.assets, assetId).asksAmount -= n;
        };
      };
      volumeStat = func(assetId) = {
        add = func(n : Nat) {
          Vec.get(stats.assets, assetId).totalAskVolume += n;
        };
        sub = func(n : Nat) {
          Vec.get(stats.assets, assetId).totalAskVolume -= n;
        };
      };
    };
    public let bidCtx : OrderCtx = {
      kind = #bid;
      assetList = func(assetInfo) = assetInfo.bids;
      assetListSet = func(assetInfo, list) { assetInfo.bids := list };
      userList = func(userInfo) = userInfo.currentBids;
      userListSet = func(userInfo, list) { userInfo.currentBids := list };

      oppositeKind = #ask;
      userOppositeList = func(userInfo) = userInfo.currentAsks;
      oppositeOrderConflictCriteria = func(orderPrice, oppositeOrderPrice) = oppositeOrderPrice <= orderPrice;

      chargeToken = func(_) = trustedAssetId;
      chargeAmount = getTotalPrice;
      priorityComparator = orderPriorityComparator;
      lowOrderSign = func(_, _, volume, price) = getTotalPrice(volume, price) < minimumOrder;

      amountStat = func(assetId) = {
        add = func(n : Nat) {
          Vec.get(stats.assets, assetId).bidsAmount += n;
        };
        sub = func(n : Nat) {
          Vec.get(stats.assets, assetId).bidsAmount -= n;
        };
      };
      volumeStat = func(assetId) = {
        add = func(n : Nat) {
          Vec.get(stats.assets, assetId).totalBidVolume += n;
        };
        sub = func(n : Nat) {
          Vec.get(stats.assets, assetId).totalBidVolume -= n;
        };
      };
    };

    // order management functions
    public func placeOrderInternal(ctx : OrderCtx, userInfo : UserInfo, accountToCharge : Account, assetId : AssetId, assetInfo : AssetInfo, order : Order) : OrderId {
      let orderId = ordersCounter;
      ordersCounter += 1;
      // update user info
      AssocList.replace<OrderId, Order>(ctx.userList(userInfo), orderId, Nat.equal, ?order) |> ctx.userListSet(userInfo, _.0);
      let (success, _) = CreditsRepo.lockCredit(accountToCharge, ctx.chargeAmount(order.volume, order.price));
      assert success;
      // update asset info
      PriorityQueue.insert(ctx.assetList(assetInfo), (orderId, order), ctx.priorityComparator)
      |> ctx.assetListSet(assetInfo, _);
      // update stats
      ctx.amountStat(assetId).add(1);
      ctx.volumeStat(assetId).add(order.volume);
      orderId;
    };

    public func cancelOrderInternal(ctx : OrderCtx, userInfo : UserInfo, orderId : OrderId) : ?Order {
      AssocList.replace(ctx.userList(userInfo), orderId, Nat.equal, null)
      |> (
        switch (_) {
          case (_, null) null;
          case (map, ?existingOrder) {
            ctx.userListSet(userInfo, map);
            // return deposit to user
            let ?sourceAcc = CreditsRepo.getAccount(userInfo, ctx.chargeToken(existingOrder.assetId)) else Prim.trap("Can never happen");
            let (success, _) = CreditsRepo.unlockCredit(sourceAcc, ctx.chargeAmount(existingOrder.volume, existingOrder.price));
            assert success;
            // remove ask from asset data
            let assetInfo = assetInfoFunc(existingOrder.assetId);
            let (upd, deleted) = PriorityQueue.findOneAndDelete<(OrderId, Order)>(ctx.assetList(assetInfo), func(id, _) = id == orderId);
            assert deleted; // should always be true unless we have a bug with asset orders and user orders out of sync
            ctx.assetListSet(assetInfo, upd);
            ctx.amountStat(existingOrder.assetId).sub(1);
            ctx.volumeStat(existingOrder.assetId).sub(existingOrder.volume);
            ?existingOrder;
          };
        }
      );
    };
  };

};
