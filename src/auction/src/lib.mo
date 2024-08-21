/// A module which implements auction functionality for various trading pairs against quote fungible token
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
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import Assets "./assets";
import Credits "./credits";
import Orders "./orders";
import Users "./users";
import { processAuction; clearAuction } "./auction_processor";
import T "./types";

module {

  public func defaultStableDataV3() : T.StableDataV3 = {
    counters = (0, 0, 0, 0);
    assets = Vec.new();
    history = null;
    users = #leaf;
    quoteSurplus = 0;
  };
  public type StableDataV3 = T.StableDataV3;
  public func migrateStableDataV3(data : StableDataV2) : StableDataV3 = {
    data with quoteSurplus = 0;
  };

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
  public type CreditInfo = Credits.CreditInfo;
  public type UserInfo = T.UserInfo;
  public type TransactionHistoryItem = T.TransactionHistoryItem;
  public type PriceHistoryItem = T.PriceHistoryItem;

  public type CancellationAction = Orders.CancellationAction;
  public type PlaceOrderAction = Orders.PlaceOrderAction;

  public type IndicativeStats = {
    clearingPrice : Float;
    clearingVolume : Nat;
    totalBidVolume : Nat;
    totalAskVolume : Nat;
  };

  public type CancelOrderError = Orders.InternalCancelOrderError or {
    #UnknownPrincipal;
  };
  public type PlaceOrderError = Orders.InternalPlaceOrderError or {
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  public class Auction(
    quoteAssetId : AssetId,
    settings : {
      volumeStepLog10 : Nat; // 3 will make volume step 1000 (denominated in quote token)
      minVolumeSteps : Nat; // == minVolume / volumeStep
      priceMaxDigits : Nat;
      minAskVolume : (AssetId, T.AssetInfo) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;

    public let users = Users.Users();
    public let credits = Credits.Credits();
    public let assets = Assets.Assets();
    public let orders = Orders.Orders(
      assets,
      credits,
      users,
      quoteAssetId,
      settings,
    );

    // ============= assets interface =============
    public func registerAssets(n : Nat) = assets.register(n);

    public func processAsset(assetId : AssetId) : () {
      if (assetId == quoteAssetId) return;
      let startInstructions = settings.performanceCounter(0);
      let assetInfo = assets.getAsset(assetId);
      let (price, volume, surplus) = processAuction(
        sessionsCounter,
        orders.asks.createOrderBookService(assetInfo),
        orders.bids.createOrderBookService(assetInfo),
      );
      assets.pushToHistory(Prim.time(), sessionsCounter, assetId, volume, price);
      if (volume > 0) {
        assetInfo.lastProcessingInstructions := Nat64.toNat(settings.performanceCounter(0) - startInstructions);
        assetInfo.lastRate := price;
        if (surplus > 0) {
          credits.quoteSurplus += surplus;
        };
      };
    };

    public func indicativeAssetStats(assetId : AssetId) : IndicativeStats {
      let assetInfo = assets.getAsset(assetId);
      let (clearingPrice, clearingVolume) = clearAuction(
        orders.asks.createOrderBookService(assetInfo),
        orders.bids.createOrderBookService(assetInfo),
      )
      |> Option.get(_, (0.0, 0));
      {
        clearingPrice;
        clearingVolume;
        totalBidVolume = assetInfo.bids.totalVolume;
        totalAskVolume = assetInfo.asks.totalVolume;
      };
    };
    // ============= assets interface =============

    // ============= credits interface ============
    public func getCredit(p : Principal, assetId : AssetId) : CreditInfo = switch (users.get(p)) {
      case (null) ({ total = 0; locked = 0; available = 0 });
      case (?ui) credits.info(ui, assetId);
    };

    public func getCredits(p : Principal) : [(AssetId, CreditInfo)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) credits.infoAll(ui);
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = users.getOrCreate(p);
      let acc = credits.getOrCreate(userInfo, assetId);
      credits.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = credits.getAccount(user, assetId) else return #err(#NoCredit);
      switch (credits.deductCredit(creditAcc, amount)) {
        case (true, balance) {
          if (balance == 0 and credits.deleteIfEmpty(user, assetId)) {
            #ok(0, func() = ignore credits.getOrCreate(user, assetId) |> credits.appendCredit(_, amount));
          } else {
            #ok(balance, func() = ignore credits.appendCredit(creditAcc, amount));
          };
        };
        case (false, _) #err(#NoCredit);
      };
    };
    // ============= credits interface ============

    // ============= orders interface =============
    public func getOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId) : ?T.Order = switch (users.get(p)) {
      case (null) null;
      case (?ui) users.findOrder(ui, kind, orderId);
    };

    public func getOrders(p : Principal, kind : { #ask; #bid }, assetId : ?AssetId) : [(OrderId, T.Order)] = switch (users.get(p)) {
      case (null) [];
      case (?ui) {
        var list = users.getOrderBook(ui, kind).map;
        switch (assetId) {
          case (?aid) list := List.filter<(OrderId, T.Order)>(list, func(_, o) = o.assetId == aid);
          case (_) {};
        };
        List.toArray(list);
      };
    };

    public func manageOrders(
      p : Principal,
      cancellations : ?Orders.CancellationAction,
      placements : [Orders.PlaceOrderAction],
    ) : R.Result<[OrderId], Orders.OrderManagementError or { #UnknownPrincipal }> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      orders.manageOrders(p, userInfo, cancellations, placements);
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
          case (#PriceDigitsOverflow x) #err(#PriceDigitsOverflow(x));
          case (#VolumeStepViolated x) #err(#VolumeStepViolated(x));
        };
        case (#err(#cancellation _)) Prim.trap("Can never happen");
      };
    };

    public func replaceOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (getOrder(p, kind, orderId)) {
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
          case (#PriceDigitsOverflow x) #err(#PriceDigitsOverflow(x));
          case (#VolumeStepViolated x) #err(#VolumeStepViolated(x));
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
    // ============= orders interface =============

    // ============ history interface =============
    public func getTransactionHistory(p : Principal, assetId : ?AssetId) : Iter.Iter<T.TransactionHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      var list = userInfo.history;
      switch (assetId) {
        case (?aid) list := List.filter<T.TransactionHistoryItem>(list, func x = x.3 == aid);
        case (_) {};
      };
      List.toIter(list);
    };

    public func getPriceHistory(assetId : ?AssetId) : Iter.Iter<T.PriceHistoryItem> {
      var list = assets.history;
      switch (assetId) {
        case (?aid) list := List.filter<T.PriceHistoryItem>(list, func x = x.2 == aid);
        case (_) {};
      };
      List.toIter(list);
    };
    // ============ history interface =============

    // ============= system interface =============
    public func share() : T.StableDataV3 = {
      counters = (sessionsCounter, orders.ordersCounter, users.usersAmount, credits.accountsAmount);
      assets = Vec.map<T.AssetInfo, T.StableAssetInfoV2>(
        assets.assets,
        func(x) = {
          lastRate = x.lastRate;
          lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      history = assets.history;
      users = (
        func() : RBTree.Tree<Principal, T.StableUserInfoV2> {
          let stableUsers = RBTree.RBTree<Principal, T.StableUserInfoV2>(Principal.compare);
          for ((p, u) in users.users.entries()) {
            stableUsers.put(
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
          stableUsers.share();
        }
      )();
      quoteSurplus = credits.quoteSurplus;
    };

    public func unshare(data : T.StableDataV3) {
      sessionsCounter := data.counters.0;
      orders.ordersCounter := data.counters.1;
      users.usersAmount := data.counters.2;
      credits.accountsAmount := data.counters.3;
      credits.quoteSurplus := data.quoteSurplus;

      assets.assets := Vec.map<T.StableAssetInfoV2, T.AssetInfo>(
        data.assets,
        func(x) = {
          asks = { var queue = null; var size = 0; var totalVolume = 0 };
          bids = { var queue = null; var size = 0; var totalVolume = 0 };
          var lastRate = x.lastRate;
          var lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      assets.history := data.history;

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
          users.putOrder(userData, #ask, oid, order);
          assets.putOrder(assets.getAsset(order.assetId), #ask, oid, order);
        };
        for ((oid, orderData) in List.toIter(u.bids.map)) {
          let order : T.Order = {
            orderData with userInfoRef = userData;
            var volume = orderData.volume;
          };
          users.putOrder(userData, #bid, oid, order);
          assets.putOrder(assets.getAsset(order.assetId), #bid, oid, order);
        };
        users.users.put(p, userData);
      };

    };
    // ============= system interface =============
  };

};
