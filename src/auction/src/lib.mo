/// A module which implements auction functionality for various trading pairs against "trusted" fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

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

import Vec "mo:vector";
import { matchOrders } "mo:auction";

import T "./types";
import PriorityQueue "./priority_queue";
import CreditsRepo "./credits_repo";
import OrdersRepo "./orders_repo";
import {
  sliceList;
  sliceListWithFilter;
  iterConcat;
} "./utils";

module {

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  type Account = CreditsRepo.Account;

  public type StableDataV1 = {
    counters : (sessions : Nat, orders : Nat);
    assets : Vec.Vector<StableAssetInfo>;
    users : RBTree.Tree<Principal, UserInfo>;
    history : List.List<PriceHistoryItem>;
    stats : {
      usersAmount : Nat;
      accountsAmount : Nat;
      assets : Vec.Vector<{ bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }>;
    };
  };

  public func defaultStableDataV1() : StableDataV1 = {
    counters = (0, 0);
    assets = Vec.new();
    users = #leaf;
    history = null;
    stats = {
      usersAmount = 0;
      accountsAmount = 0;
      assets = Vec.new();
    };
  };

  public type CreditInfo = CreditsRepo.CreditInfo;

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type Order = OrdersRepo.Order;
  type OrderCtx = OrdersRepo.OrderCtx;

  public type SharedOrder = {
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };

  public type UserInfo = {
    var currentAsks : AssocList.AssocList<OrderId, Order>;
    var currentBids : AssocList.AssocList<OrderId, Order>;
    var credits : AssocList.AssocList<AssetId, CreditsRepo.Account>;
    var history : List.List<TransactionHistoryItem>;
  };

  public type StableAssetInfo = {
    asks : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    bids : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    lastRate : Float;
  };

  public type AssetInfo = {
    var asks : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var bids : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var lastRate : Float;
  };

  public type CancellationAction = {
    #all : ?[AssetId];
    #orders : [{ #ask : OrderId; #bid : OrderId }];
  };

  public type PlaceOrderAction = {
    #ask : (assetId : AssetId, volume : Nat, price : Float);
    #bid : (assetId : AssetId, volume : Nat, price : Float);
  };

  type InternalCancelOrderError = { #UnknownOrder };
  type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
  };

  public type OrderManagementError = {
    #UnknownPrincipal;
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

  public type CancelOrderError = InternalCancelOrderError or {
    #UnknownPrincipal;
  };
  public type PlaceOrderError = InternalPlaceOrderError or {
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  public func getTotalPrice(volume : Nat, unitPrice : Float) : Nat = Int.abs(Float.toInt(Float.ceil(unitPrice * Float.fromInt(volume))));

  public class Auction(
    trustedAssetId : AssetId,
    settings : {
      minimumOrder : Nat;
      minAskVolume : (AssetId, AssetInfo) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;
    // asset info, index == assetId
    public var assets : Vec.Vector<AssetInfo> = Vec.new();
    // user info
    public let users : RBTree.RBTree<Principal, UserInfo> = RBTree.RBTree<Principal, UserInfo>(Principal.compare);
    // asset history
    public var history : List.List<PriceHistoryItem> = null;
    // stats
    public let stats : {
      var usersAmount : Nat;
      var accountsAmount : Nat;
      var assets : Vec.Vector<{ var bidsAmount : Nat; var totalBidVolume : Nat; var asksAmount : Nat; var totalAskVolume : Nat; var lastProcessingInstructions : Nat }>;
    } = {
      var usersAmount = 0;
      var accountsAmount = 0;
      var assets = Vec.new();
    };
    // orders repo
    public let ordersRepo = OrdersRepo.OrdersRepo(trustedAssetId, settings.minimumOrder, settings.minAskVolume, stats, func(assetId : AssetId) : AssetInfo = Vec.get(assets, assetId));

    public func initUser(p : Principal) : UserInfo {
      let data : UserInfo = {
        var currentAsks = null;
        var currentBids = null;
        var credits = null;
        var history = null;
      };
      let oldValue = users.replace(p, data);
      switch (oldValue) {
        case (?_) Prim.trap("Prevented user data overwrite");
        case (_) {};
      };
      stats.usersAmount += 1;
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
            var lastRate = 0;
          } : AssetInfo
        )
        |> Vec.add(assets, _);
        ({
          var asksAmount = 0;
          var bidsAmount = 0;
          var lastProcessingInstructions = 0;
          var totalAskVolume = 0;
          var totalBidVolume = 0;
        })
        |> Vec.add(stats.assets, _);
        assetsVecSize += 1;
      };
    };

    public func queryCredit(p : Principal, assetId : AssetId) : CreditInfo = users.get(p)
    |> Option.chain<UserInfo, Account>(_, func(info) = CreditsRepo.getAccount(info, assetId))
    |> Option.map<Account, CreditInfo>(_, func(acc) = CreditsRepo.info(acc))
    |> Option.get(_, { total = 0; locked = 0; available = 0 });

    public func queryCredits(p : Principal) : [(AssetId, CreditInfo)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        let length = List.size(ui.credits);
        var list = ui.credits;
        Array.tabulate<(AssetId, CreditInfo)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?x) (x.0, CreditsRepo.info(x.1));
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

    private func queryOrder_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, Order>, orderId : OrderId) : ?SharedOrder {
      switch (users.get(p)) {
        case (null) null;
        case (?ui) {
          for ((oid, order) in List.toIter(f(ui))) {
            if (oid == orderId) {
              return ?{ order with volume = order.volume };
            };
          };
          null;
        };
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

    public func queryAsk(p : Principal, orderId : OrderId) : ?SharedOrder = queryOrder_(p, func(info) = info.currentAsks, orderId);
    public func queryBid(p : Principal, orderId : OrderId) : ?SharedOrder = queryOrder_(p, func(info) = info.currentBids, orderId);

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
      let (acc, isNew) = CreditsRepo.getOrCreateAccount(userInfo, assetId);
      if (isNew) {
        stats.accountsAmount += 1;
      };
      CreditsRepo.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = CreditsRepo.getAccount(user, assetId) else return #err(#NoCredit);
      switch (CreditsRepo.deductCredit(creditAcc, amount)) {
        case (true, balance) #ok(balance, func() = ignore CreditsRepo.appendCredit(creditAcc, amount));
        case (false, _) #err(#NoCredit);
      };
    };

    // public interface
    public func manageOrders(
      p : Principal,
      cancellations : ?CancellationAction,
      placements : [PlaceOrderAction],
    ) : R.Result<[OrderId], OrderManagementError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);

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
                case (?((orderId, _), _)) ignore ordersRepo.cancelOrderInternal(ctx, userInfo, orderId);
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
              ignore ordersRepo.cancelOrderInternal(ctx, userInfo, orderId);
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
          prepareBulkCancelation(ordersRepo.askCtx);
          prepareBulkCancelation(ordersRepo.bidCtx);
        };
        case (? #all(?aids)) {
          asksDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          prepareBulkCancelationWithFilter(ordersRepo.askCtx, asksDelta.isOrderCancelled);
          prepareBulkCancelationWithFilter(ordersRepo.bidCtx, bidsDelta.isOrderCancelled);
        };
        case (? #orders(orders)) {
          let cancelledAsks : RBTree.RBTree<OrderId, ()> = RBTree.RBTree(Nat.compare);
          let cancelledBids : RBTree.RBTree<OrderId, ()> = RBTree.RBTree(Nat.compare);
          asksDelta.isOrderCancelled := func(_, orderId) = cancelledAsks.get(orderId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(_, orderId) = cancelledBids.get(orderId) |> not Option.isNull(_);

          for (i in orders.keys()) {
            let (ctx, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (ordersRepo.askCtx, orderId, cancelledAsks);
              case (#bid orderId) (ordersRepo.bidCtx, orderId, cancelledBids);
            };
            let ?oldOrder = AssocList.find(ctx.userList(userInfo), orderId, Nat.equal) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(ctx, oldOrder);
            cancelledTree.put(orderId, ());
            cancellationCommitActions := List.push(
              func() = ignore ordersRepo.cancelOrderInternal(ctx, userInfo, orderId),
              cancellationCommitActions,
            );
          };
        };
      };

      // validate and prepare placements
      for (i in placements.keys()) {
        let (ctx, (assetId, volume, price), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (ordersRepo.askCtx, args, asksDelta, bidsDelta);
          case (#bid(args)) (ordersRepo.bidCtx, args, bidsDelta, asksDelta);
        };

        // validate asset id
        if (assetId == trustedAssetId or assetId >= Vec.size(assets)) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume
        let assetInfo = Vec.get(assets, assetId);
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

        placementCommitActions[i] := func() = ordersRepo.placeOrderInternal(ctx, userInfo, chargeAcc, assetId, assetInfo, order);
      };

      // commit changes, return results
      for (cancel in List.toIter(cancellationCommitActions)) {
        cancel();
      };
      #ok(Array.tabulate<OrderId>(placementCommitActions.size(), func(i) = placementCommitActions[i]()));
    };

    public func placeAsk(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      switch (manageOrders(p, null, [#ask(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
        case (_) Prim.trap("Can never happen");
      };
    };

    public func replaceAsk(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (queryAsk(p, orderId)) {
        case (?ask) ask.assetId;
        case (null) return #err(#UnknownOrder);
      };
      switch (manageOrders(p, ? #orders([#ask(orderId)]), [#ask(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) switch (error) {
          case (#UnknownOrder) #err(#UnknownOrder);
        };
        case (#err(#placement({ error }))) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
      };
    };

    public func cancelAsk(p : Principal, orderId : OrderId) : R.Result<(), CancelOrderError> {
      switch (manageOrders(p, ? #orders([#ask(orderId)]), [])) {
        case (#ok _) #ok();
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement _)) Prim.trap("Can never happen");
        case (#err(#cancellation({ error }))) switch (error) {
          case (#UnknownOrder) #err(#UnknownOrder);
        };
      };
    };

    public func placeBid(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      switch (manageOrders(p, null, [#bid(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
        case (_) Prim.trap("Can never happen");
      };
    };

    public func replaceBid(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (queryBid(p, orderId)) {
        case (?bid) bid.assetId;
        case (null) return #err(#UnknownOrder);
      };
      switch (manageOrders(p, ? #orders([#bid(orderId)]), [#bid(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement({ error }))) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
      };
    };

    public func cancelBid(p : Principal, orderId : OrderId) : R.Result<(), CancelOrderError> {
      switch (manageOrders(p, ? #orders([#bid(orderId)]), [])) {
        case (#ok _) #ok();
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };

    // processes auction for given asset
    public func processAsset(assetId : AssetId) : () {
      if (assetId == trustedAssetId) return;
      let startInstructions = settings.performanceCounter(0);

      let assetInfo = Vec.get(assets, assetId);
      let mapOrders = func(orders : List.List<(OrderId, Order)>) : Iter.Iter<(Float, Nat)> = orders
      |> List.toIter<(OrderId, Order)>(_)
      |> Iter.map<(OrderId, Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

      let (nAsks, nBids, dealVolume, price) = matchOrders(mapOrders(assetInfo.asks), mapOrders(assetInfo.bids));
      if (nAsks == 0 or nBids == 0) {
        history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), history);
        return;
      };

      let assetStats = Vec.get(stats.assets, assetId);

      // process fulfilled asks
      var i = 0;
      var dealVolumeLeft = dealVolume;
      var asksTail = assetInfo.asks;
      label b while (i < nAsks) {
        let ?((orderId, order), next) = asksTail else Prim.trap("Can never happen: list shorter than before");
        let userInfo = order.userInfoRef;
        // update ask in user info and calculate real ask volume
        let volume = if (i + 1 == nAsks and dealVolumeLeft != order.volume) {
          order.volume -= dealVolumeLeft;
          dealVolumeLeft;
        } else {
          AssocList.replace<OrderId, Order>(userInfo.currentAsks, orderId, Nat.equal, null) |> (userInfo.currentAsks := _.0);
          asksTail := next;
          assetStats.asksAmount -= 1;
          dealVolumeLeft -= order.volume;
          order.volume;
        };
        // remove price from deposit
        let ?sourceAcc = CreditsRepo.getAccount(userInfo, assetId) else Prim.trap("Can never happen");
        sourceAcc.credit -= volume;
        // unlock locked deposit
        let (success, _) = CreditsRepo.unlockCredit(sourceAcc, volume);
        assert success;
        // credit user with trusted tokens
        let (acc, isNew) = CreditsRepo.getOrCreateAccount(userInfo, trustedAssetId);
        if (isNew) {
          stats.accountsAmount += 1;
        };
        ignore CreditsRepo.appendCredit(acc, getTotalPrice(volume, price));
        // update stats
        assetStats.totalAskVolume -= volume;
        // append to history
        userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
        i += 1;
      };
      assetInfo.asks := asksTail;

      // process fulfilled bids
      i := 0;
      dealVolumeLeft := dealVolume;
      var bidsTail = assetInfo.bids;
      label b while (i < nBids) {
        let ?((orderId, order), next) = bidsTail else Prim.trap("Can never happen: list shorter than before");
        let userInfo = order.userInfoRef;
        // update bid in user info and calculate real bid volume
        let volume = if (i + 1 == nBids and dealVolumeLeft != order.volume) {
          order.volume -= dealVolumeLeft;
          dealVolumeLeft;
        } else {
          AssocList.replace<OrderId, Order>(userInfo.currentBids, orderId, Nat.equal, null) |> (userInfo.currentBids := _.0);
          bidsTail := next;
          assetStats.bidsAmount -= 1;
          dealVolumeLeft -= order.volume;
          order.volume;
        };
        // remove price from deposit
        let ?trustedAcc = CreditsRepo.getAccount(userInfo, trustedAssetId) else Prim.trap("Can never happen");
        trustedAcc.credit -= getTotalPrice(volume, price);
        // unlock locked deposit (note that it uses bid price)
        let (success, _) = CreditsRepo.unlockCredit(trustedAcc, getTotalPrice(volume, order.price));
        assert success;
        // credit user with tokens
        let (acc, isNew) = CreditsRepo.getOrCreateAccount(userInfo, assetId);
        if (isNew) {
          stats.accountsAmount += 1;
        };
        ignore CreditsRepo.appendCredit(acc, volume);
        // update stats
        assetStats.totalBidVolume -= volume;
        // append to history
        userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
        i += 1;
      };
      assetInfo.bids := bidsTail;

      assetInfo.lastRate := price;
      // append to asset history
      history := List.push((Prim.time(), sessionsCounter, assetId, dealVolume, price), history);
      assetStats.lastProcessingInstructions := Nat64.toNat(settings.performanceCounter(0) - startInstructions);
    };

    public func share() : StableDataV1 = {
      counters = (sessionsCounter, ordersRepo.ordersCounter);
      assets = Vec.map<AssetInfo, StableAssetInfo>(
        assets,
        func(x) = {
          asks = x.asks;
          bids = x.bids;
          lastRate = x.lastRate;
        },
      );
      stats = {
        usersAmount = stats.usersAmount;
        accountsAmount = stats.accountsAmount;
        assets = Vec.map<{ var bidsAmount : Nat; var totalBidVolume : Nat; var asksAmount : Nat; var totalAskVolume : Nat; var lastProcessingInstructions : Nat }, { bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }>(
          stats.assets,
          func(x) = {
            bidsAmount = x.bidsAmount;
            totalBidVolume = x.totalBidVolume;
            asksAmount = x.asksAmount;
            totalAskVolume = x.totalAskVolume;
            lastProcessingInstructions = x.lastProcessingInstructions;
          },
        );
      };
      users = users.share();
      history = history;
    };

    public func unshare(data : StableDataV1) {
      sessionsCounter := data.counters.0;
      ordersRepo.ordersCounter := data.counters.1;
      assets := Vec.map<StableAssetInfo, AssetInfo>(
        data.assets,
        func(x) = {
          var asks = x.asks;
          var bids = x.bids;
          var lastRate = x.lastRate;
        },
      );
      stats.usersAmount := data.stats.usersAmount;
      stats.accountsAmount := data.stats.accountsAmount;
      stats.assets := Vec.map<{ bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }, { var bidsAmount : Nat; var totalBidVolume : Nat; var asksAmount : Nat; var totalAskVolume : Nat; var lastProcessingInstructions : Nat }>(
        data.stats.assets,
        func(x) = {
          var bidsAmount = x.bidsAmount;
          var totalBidVolume = x.totalBidVolume;
          var asksAmount = x.asksAmount;
          var totalAskVolume = x.totalAskVolume;
          var lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      users.unshare(data.users);
      history := data.history;
    };

  };

};
