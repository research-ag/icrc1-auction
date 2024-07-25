import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import List "mo:base/List";
import Nat "mo:base/Nat";
import O "mo:base/Order";
import Prim "mo:prim";

import Vec "mo:vector";

// remove dependency
import CreditsRepo "./credits_repo";
import PriorityQueue "./priority_queue";
import T "./types";
import {
  flipOrder;
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
  ) {

    // a counter of ever added order
    public var ordersCounter = 0;

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
