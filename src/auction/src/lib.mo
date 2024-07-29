/// A module which implements auction functionality for various trading pairs against "trusted" fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import AssetsRepo "assets_repo";
import CreditsRepo "./credits_repo";
import OrdersRepo "./orders_repo";
import { processAuction } "./auction_processor";
import {
  sliceList;
  sliceListWithFilter;
} "./utils";
import T "./types";
import UsersRepo "users_repo";

module {

  public func defaultStableDataV2() : T.StableDataV2 = {
    counters = (0, 0, 0, 0);
    assets = Vec.new();
    history = null;
    users = #leaf;
  };
  public type StableDataV2 = T.StableDataV2;
  public func migrateStableDataV2(data : StableDataV1) : StableDataV2 {
    let assets : Vec.Vector<T.StableAssetInfoV2> = Vec.new();
    for (i in Vec.keys(data.assets)) {
      let x = Vec.get(data.assets, i);
      let xs = Vec.get(data.stats.assets, i);
      Vec.add(
        assets,
        {
          lastRate = x.lastRate;
          lastProcessingInstructions = xs.lastProcessingInstructions;
        },
      );
    };
    let usersData = RBTree.RBTree<Principal, T.StableUserInfoV1>(Principal.compare);
    usersData.unshare(data.users);
    let users = RBTree.RBTree<Principal, T.StableUserInfoV2>(Principal.compare);
    for ((p, u) in usersData.entries()) {
      users.put(
        p,
        {
          asks = {
            var map = List.map<(T.OrderId, T.StableOrderV1), (T.OrderId, T.StableOrderDataV2)>(u.currentAsks, func(oid, o) = (oid, { assetId = o.assetId; price = o.price; user = o.user; volume = o.volume }));
          };
          bids = {
            var map = List.map<(T.OrderId, T.StableOrderV1), (T.OrderId, T.StableOrderDataV2)>(u.currentBids, func(oid, o) = (oid, { assetId = o.assetId; price = o.price; user = o.user; volume = o.volume }));
          };
          credits = u.credits;
          history = u.history;
        },
      );
    };
    {
      counters = (data.counters.0, data.counters.1, data.stats.usersAmount, data.stats.accountsAmount);
      assets = assets;
      history = data.history;
      users = users.share();
    };
  };

  public func defaultStableDataV1() : T.StableDataV1 = {
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
  public type StableDataV1 = T.StableDataV1;

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  public type CreditInfo = CreditsRepo.CreditInfo;
  public type SharedOrder = T.SharedOrder;
  public type UserInfo = T.UserInfo;

  public type CancellationAction = OrdersRepo.CancellationAction;
  public type PlaceOrderAction = OrdersRepo.PlaceOrderAction;

  public type CancelOrderError = OrdersRepo.InternalCancelOrderError or {
    #UnknownPrincipal;
  };
  public type PlaceOrderError = OrdersRepo.InternalPlaceOrderError or {
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  public class Auction(
    trustedAssetId : AssetId,
    settings : {
      minimumOrder : Nat;
      minAskVolume : (AssetId, T.AssetInfo) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;

    public let usersRepo = UsersRepo.UsersRepo();
    public let creditsRepo = CreditsRepo.CreditsRepo();
    public let assetsRepo = AssetsRepo.AssetsRepo();
    public let ordersRepo = OrdersRepo.OrdersRepo(
      assetsRepo,
      creditsRepo,
      trustedAssetId,
      settings.minimumOrder,
      settings.minAskVolume,
    );

    public func registerAssets(n : Nat) = assetsRepo.register(n);

    public func queryCredit(p : Principal, assetId : AssetId) : CreditInfo = switch (usersRepo.get(p)) {
      case (null) ({ total = 0; locked = 0; available = 0 });
      case (?ui) creditsRepo.info(ui, assetId);
    };

    public func queryCredits(p : Principal) : [(AssetId, CreditInfo)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) creditsRepo.infoAll(ui);
    };

    private func queryOrders_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, T.Order>) : [(OrderId, T.SharedOrder)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) {
        var list = f(ui);
        let length = List.size(list);
        Array.tabulate<(OrderId, T.SharedOrder)>(
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

    private func queryOrder_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, T.Order>, orderId : OrderId) : ?T.SharedOrder {
      switch (usersRepo.get(p)) {
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

    public func queryAssetAsks(p : Principal, assetId : AssetId) : [(OrderId, T.SharedOrder)] = queryOrders_(
      p,
      func(info) = info.asks.map |> List.filter<(OrderId, T.Order)>(_, func(_, o) = o.assetId == assetId),
    );
    public func queryAssetBids(p : Principal, assetId : AssetId) : [(OrderId, T.SharedOrder)] = queryOrders_(
      p,
      func(info) = info.bids.map |> List.filter<(OrderId, T.Order)>(_, func(_, o) = o.assetId == assetId),
    );

    public func queryAsks(p : Principal) : [(OrderId, T.SharedOrder)] = queryOrders_(p, func(info) = info.asks.map);
    public func queryBids(p : Principal) : [(OrderId, T.SharedOrder)] = queryOrders_(p, func(info) = info.bids.map);

    public func queryAsk(p : Principal, orderId : OrderId) : ?T.SharedOrder = queryOrder_(p, func(info) = info.asks.map, orderId);
    public func queryBid(p : Principal, orderId : OrderId) : ?T.SharedOrder = queryOrder_(p, func(info) = info.bids.map, orderId);

    public func queryTransactionHistory(p : Principal, assetId : ?AssetId, limit : Nat, skip : Nat) : [T.TransactionHistoryItem] {
      let ?userInfo = usersRepo.get(p) else return [];
      switch (assetId) {
        case (?aid) sliceListWithFilter(userInfo.history, func(item : T.TransactionHistoryItem) : Bool = item.3 == aid, limit, skip);
        case (null) sliceList(userInfo.history, limit, skip);
      };
    };

    public func queryPriceHistory(assetId : ?AssetId, limit : Nat, skip : Nat) : [T.PriceHistoryItem] {
      switch (assetId) {
        case (?aid) sliceListWithFilter(assetsRepo.history, func(item : T.PriceHistoryItem) : Bool = item.2 == aid, limit, skip);
        case (null) sliceList(assetsRepo.history, limit, skip);
      };
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = usersRepo.getOrCreate(p);
      let acc = creditsRepo.getOrCreate(userInfo, assetId);
      creditsRepo.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = usersRepo.get(p) else return #err(#NoCredit);
      let ?creditAcc = creditsRepo.getAccount(user, assetId) else return #err(#NoCredit);
      switch (creditsRepo.deductCredit(creditAcc, amount)) {
        case (true, balance) #ok(balance, func() = ignore creditsRepo.appendCredit(creditAcc, amount));
        case (false, _) #err(#NoCredit);
      };
    };

    public func manageOrders(
      p : Principal,
      cancellations : ?OrdersRepo.CancellationAction,
      placements : [OrdersRepo.PlaceOrderAction],
    ) : R.Result<[OrderId], OrdersRepo.OrderManagementError or { #UnknownPrincipal }> {
      let ?userInfo = usersRepo.get(p) else return #err(#UnknownPrincipal);
      ordersRepo.manageOrders(p, userInfo, cancellations, placements);
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
      processAuction(assetsRepo, creditsRepo, assetId, sessionsCounter, trustedAssetId, settings.performanceCounter);
    };

    public func share() : T.StableDataV2 = {
      counters = (sessionsCounter, ordersRepo.ordersCounter, usersRepo.usersAmount, creditsRepo.accountsAmount);
      assets = Vec.map<T.AssetInfo, T.StableAssetInfoV2>(
        assetsRepo.assets,
        func(x) = {
          lastRate = x.lastRate;
          lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      history = assetsRepo.history;
      users = (
        func() : RBTree.Tree<Principal, T.StableUserInfoV2> {
          let users = RBTree.RBTree<Principal, T.StableUserInfoV2>(Principal.compare);
          for ((p, u) in usersRepo.users.entries()) {
            users.put(
              p,
              {
                asks = {
                  var map = List.map<(T.OrderId, T.Order), (T.OrderId, T.StableOrderDataV2)>(u.asks.map, func(oid, o) = (oid, { assetId = o.assetId; price = o.price; user = o.user; volume = o.volume }));
                };
                bids = {
                  var map = List.map<(T.OrderId, T.Order), (T.OrderId, T.StableOrderDataV2)>(u.bids.map, func(oid, o) = (oid, { assetId = o.assetId; price = o.price; user = o.user; volume = o.volume }));
                };
                credits = u.credits;
                history = u.history;
              },
            );
          };
          users.share();
        }
      )();
    };

    public func unshare(data : T.StableDataV2) {
      sessionsCounter := data.counters.0;
      ordersRepo.ordersCounter := data.counters.1;
      usersRepo.usersAmount := data.counters.2;
      creditsRepo.accountsAmount := data.counters.3;

      assetsRepo.assets := Vec.map<T.StableAssetInfoV2, T.AssetInfo>(
        data.assets,
        func(x) = {
          asks = { var queue = null; var amount = 0; var totalVolume = 0 };
          bids = { var queue = null; var amount = 0; var totalVolume = 0 };
          var lastRate = x.lastRate;
          var lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      assetsRepo.history := data.history;

      let ud = RBTree.RBTree<Principal, T.StableUserInfoV2>(Principal.compare);
      ud.unshare(data.users);
      for ((p, u) in ud.entries()) {
        let userData : UserInfo = {
          asks = {
            var map = null;
          };
          bids = {
            var map = null;
          };
          var credits = u.credits;
          var history = u.history;
        };
        for ((oid, orderData) in List.toIter(u.asks.map)) {
          let order : T.Order = {
            orderData with userInfoRef = userData;
            var volume = orderData.volume;
          };
          assetsRepo.putOrder(Vec.get(assetsRepo.assets, order.assetId), #ask, oid, order);
        };
        for ((oid, orderData) in List.toIter(u.bids.map)) {
          let order : T.Order = {
            orderData with userInfoRef = userData;
            var volume = orderData.volume;
          };
          assetsRepo.putOrder(Vec.get(assetsRepo.assets, order.assetId), #bid, oid, order);
        };
        usersRepo.users.put(p, userData);
      };

    };

  };

};
