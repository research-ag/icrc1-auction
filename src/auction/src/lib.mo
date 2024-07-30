/// A module which implements auction functionality for various trading pairs against "trusted" fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
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
  public type Order = T.Order;
  public type CreditInfo = CreditsRepo.CreditInfo;
  public type UserInfo = T.UserInfo;
  public type TransactionHistoryItem = T.TransactionHistoryItem;
  public type PriceHistoryItem = T.PriceHistoryItem;

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
      usersRepo,
      trustedAssetId,
      settings.minimumOrder,
      settings.minAskVolume,
    );

    public func registerAssets(n : Nat) = assetsRepo.register(n);

    // TODO rename queries below
    public func queryCredit(p : Principal, assetId : AssetId) : CreditInfo = switch (usersRepo.get(p)) {
      case (null) ({ total = 0; locked = 0; available = 0 });
      case (?ui) creditsRepo.info(ui, assetId);
    };

    public func queryCredits(p : Principal) : [(AssetId, CreditInfo)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) creditsRepo.infoAll(ui);
    };

    public func queryOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId) : ?T.Order = switch (usersRepo.get(p)) {
      case (null) null;
      case (?ui) usersRepo.findOrder(ui, kind, orderId);
    };

    public func queryOrders(p : Principal, kind : { #ask; #bid }, assetId : ?AssetId) : [(OrderId, T.Order)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) {
        var list = usersRepo.getOrderBook(ui, kind).map;
        switch (assetId) {
          case (?aid) list := List.filter<(OrderId, T.Order)>(list, func(_, o) = o.assetId == aid);
          case (_) {};
        };
        List.toArray(list);
      };
    };

    public func getTransactionHistory(p : Principal, assetId : ?AssetId) : Iter.Iter<T.TransactionHistoryItem> {
      let ?userInfo = usersRepo.get(p) else return { next = func() = null };
      var list = userInfo.history;
      switch (assetId) {
        case (?aid) list := List.filter<T.TransactionHistoryItem>(list, func x = x.3 == aid);
        case (_) {};
      };
      List.toIter(list);
    };

    public func getPriceHistory(assetId : ?AssetId) : Iter.Iter<T.PriceHistoryItem> {
      var list = assetsRepo.history;
      switch (assetId) {
        case (?aid) list := List.filter<T.PriceHistoryItem>(list, func x = x.2 == aid);
        case (_) {};
      };
      List.toIter(list);
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

    public func placeOrder(p : Principal, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      let placement = switch (kind) {
        case (#ask) #ask(assetId, volume, price);
        case (#bid) #bid(assetId, volume, price);
      };
      switch (manageOrders(p, null, [placement])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
        case (#err(#cancellation _)) Prim.trap("Can never happen");
      };
    };

    public func replaceOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (queryOrder(p, kind, orderId)) {
        case (?o) o.assetId;
        case (null) return #err(#UnknownOrder);
      };
      let (cancellation, placement) = switch (kind) {
        case (#ask) (#ask(orderId), #ask(assetId, volume, price));
        case (#bid) (#bid(orderId), #bid(assetId, volume, price));
      };
      switch (manageOrders(p, ? #orders([cancellation]), [placement])) {
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

    public func cancelOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId) : R.Result<(), CancelOrderError> {
      let cancellation = switch (kind) {
        case (#ask) #ask(orderId);
        case (#bid) #bid(orderId);
      };
      switch (manageOrders(p, ? #orders([cancellation]), [])) {
        case (#ok _) #ok();
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };

    public func processAsset(assetId : AssetId) : () {
      if (assetId == trustedAssetId) return;
      processAuction(assetsRepo, creditsRepo, usersRepo, assetId, sessionsCounter, trustedAssetId, settings.performanceCounter);
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
          usersRepo.putOrder(userData, #ask, oid, order);
          assetsRepo.putOrder(Vec.get(assetsRepo.assets, order.assetId), #ask, oid, order);
        };
        for ((oid, orderData) in List.toIter(u.bids.map)) {
          let order : T.Order = {
            orderData with userInfoRef = userData;
            var volume = orderData.volume;
          };
          usersRepo.putOrder(userData, #bid, oid, order);
          assetsRepo.putOrder(Vec.get(assetsRepo.assets, order.assetId), #bid, oid, order);
        };
        usersRepo.users.put(p, userData);
      };

    };

  };

};
