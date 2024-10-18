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

  public func defaultStableDataV6() : T.StableDataV6 = {
    assets = Vec.new();
    orders = { globalCounter = 0; fulfilledCounter = 0 };
    quoteToken = { totalProcessedVolume = 0; surplus = 0 };
    sessions = { counter = 0; history = Vec.new<T.PriceHistoryItem>() };
    users = {
      registry = {
        tree = #leaf;
        size = 0;
      };
      participantsArchive = {
        tree = #leaf;
        size = 0;
      };
      accountsAmount = 0;
    };
  };
  public type StableDataV6 = T.StableDataV6;
  public func migrateStableDataV6(data : StableDataV5) : StableDataV6 {
    let usersTree : RBTree.RBTree<Principal, T.StableUserInfoV4> = RBTree.RBTree(Principal.compare);
    for ((p, x) in RBTree.iter(data.users.registry.tree, #bwd)) {
      usersTree.put(p, { x with transactionHistory = x.history; depositHistory = Vec.new<T.DepositHistoryItem>() });
    };
    {
      data with
      users = {
        data.users with registry = {
          data.users.registry with tree = usersTree.share()
        }
      };
    };
  };

  public func defaultStableDataV5() : T.StableDataV5 = {
    assets = Vec.new();
    orders = { globalCounter = 0; fulfilledCounter = 0 };
    quoteToken = { totalProcessedVolume = 0; surplus = 0 };
    sessions = { counter = 0; history = Vec.new<T.PriceHistoryItem>() };
    users = {
      registry = {
        tree = #leaf;
        size = 0;
      };
      participantsArchive = {
        tree = #leaf;
        size = 0;
      };
      accountsAmount = 0;
    };
  };
  public type StableDataV5 = T.StableDataV5;
  public func migrateStableDataV5(data : StableDataV4) : StableDataV5 {

    func listToVecRev<A>(l : List.List<A>, defaultValue : A) : Vec.Vector<A> {
      let amount = List.size(l);
      let v : Vec.Vector<A> = Vec.init(amount, defaultValue);
      var i : Int = amount - 1;
      for (x in List.toIter(l)) {
        Vec.put<A>(v, Int.abs(i), x);
        i -= 1;
      };
      v;
    };

    let usersTree : RBTree.RBTree<Principal, T.StableUserInfoV3> = RBTree.RBTree(Principal.compare);
    for ((p, x) in RBTree.iter(data.users.registry.tree, #bwd)) {
      usersTree.put(p, { x with history = listToVecRev<T.TransactionHistoryItem>(x.history, (0, 0, #ask, 0, 0, 0.0)) });
    };

    {
      data with
      sessions = {
        data.sessions with history = listToVecRev<T.PriceHistoryItem>(data.sessions.history, (0, 0, 0, 0, 0.0))
      };
      users = {
        data.users with registry = {
          data.users.registry with tree = usersTree.share()
        }
      };
    };
  };

  public func defaultStableDataV4() : T.StableDataV4 = {
    assets = Vec.new();
    orders = { globalCounter = 0; fulfilledCounter = 0 };
    quoteToken = { totalProcessedVolume = 0; surplus = 0 };
    sessions = { counter = 0; history = null };
    users = {
      registry = {
        tree = #leaf;
        size = 0;
      };
      participantsArchive = {
        tree = #leaf;
        size = 0;
      };
      accountsAmount = 0;
    };
  };
  public type StableDataV4 = T.StableDataV4;
  public func migrateStableDataV4(data : StableDataV3) : StableDataV4 {
    var participantsArchive : RBTree.RBTree<Principal, { lastOrderPlacement : Nat64 }> = RBTree.RBTree(Principal.compare);
    for ((p, user) in RBTree.iter(data.users, #fwd)) {
      participantsArchive.put(p, { lastOrderPlacement = Prim.time() });
    };

    {
      assets = data.assets;
      orders = {
        globalCounter = data.counters.1;
        fulfilledCounter = 0;
      };
      quoteToken = { totalProcessedVolume = 0; surplus = data.quoteSurplus };
      sessions = { counter = data.counters.0; history = data.history };
      users = {
        registry = {
          tree = data.users;
          size = data.counters.2;
        };
        participantsArchive = {
          tree = participantsArchive.share();
          size = data.counters.2;
        };
        accountsAmount = data.counters.3;
      };
    };
  };

  public func defaultStableDataV3() : T.StableDataV3 = {
    counters = (0, 0, 0, 0);
    assets = Vec.new();
    history = null;
    users = #leaf;
    quoteSurplus = 0;
  };
  public type StableDataV3 = T.StableDataV3;

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  public type Order = T.Order;
  public type CreditInfo = Credits.CreditInfo;
  public type UserInfo = T.UserInfo;
  public type DepositHistoryItem = T.DepositHistoryItem;
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

  public type ManageOrdersError = Orders.OrderManagementError or {
    #UnknownPrincipal;
  };
  public type CancelOrderError = Orders.InternalCancelOrderError or {
    #SessionNumberMismatch : T.AssetId;
    #UnknownPrincipal;
  };
  public type PlaceOrderError = Orders.InternalPlaceOrderError or {
    #SessionNumberMismatch : T.AssetId;
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
    public func getAssetSessionNumber(assetId : AssetId) : Nat = assets.getAsset(assetId).sessionsCounter;

    public func registerAssets(n : Nat) = assets.register(n, sessionsCounter);

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
      assetInfo.lastProcessingInstructions := Nat64.toNat(settings.performanceCounter(0) - startInstructions);
      assetInfo.sessionsCounter := sessionsCounter + 1;
      if (volume > 0) {
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
      Vec.add<T.DepositHistoryItem>(userInfo.depositHistory, (Prim.time(), #deposit, assetId, amount));
      credits.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = credits.getAccount(user, assetId) else return #err(#NoCredit);
      switch (credits.deductCredit(creditAcc, amount)) {
        case (true, balance) {
          Vec.add<T.DepositHistoryItem>(user.depositHistory, (Prim.time(), #withdrawal, assetId, amount));
          if (balance == 0 and credits.deleteIfEmpty(user, assetId)) {
            #ok(
              0,
              func() {
                ignore credits.getOrCreate(user, assetId) |> credits.appendCredit(_, amount);
                Vec.add<T.DepositHistoryItem>(user.depositHistory, (Prim.time(), #withdrawalRollback, assetId, amount));
              },
            );
          } else {
            #ok(
              balance,
              func() {
                ignore credits.appendCredit(creditAcc, amount);
                Vec.add<T.DepositHistoryItem>(user.depositHistory, (Prim.time(), #withdrawalRollback, assetId, amount));
              },
            );
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
      expectedSessionNumber : ?Nat,
    ) : R.Result<[OrderId], ManageOrdersError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      orders.manageOrders(p, userInfo, cancellations, placements, expectedSessionNumber);
    };

    public func placeOrder(p : Principal, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float, expectedSessionNumber : ?Nat) : R.Result<OrderId, PlaceOrderError> {
      let placement = switch (kind) {
        case (#ask) #ask(assetId, volume, price);
        case (#bid) #bid(assetId, volume, price);
      };
      switch (manageOrders(p, null, [placement], expectedSessionNumber)) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#SessionNumberMismatch x)) #err(#SessionNumberMismatch(x));
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) #err(error);
        case (#err(#cancellation _)) Prim.trap("Can never happen");
      };
    };

    public func replaceOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, volume : Nat, price : Float, expectedSessionNumber : ?Nat) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (getOrder(p, kind, orderId)) {
        case (?o) o.assetId;
        case (null) return #err(#UnknownOrder);
      };
      let (cancellation, placement) = switch (kind) {
        case (#ask) (#ask(orderId), #ask(assetId, volume, price));
        case (#bid) (#bid(orderId), #bid(assetId, volume, price));
      };
      switch (manageOrders(p, ? #orders([cancellation]), [placement], expectedSessionNumber)) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#SessionNumberMismatch x)) #err(#SessionNumberMismatch(x));
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement({ error }))) #err(error);
      };
    };

    public func cancelOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, expectedSessionNumber : ?Nat) : R.Result<(), CancelOrderError> {
      let cancellation = switch (kind) {
        case (#ask) #ask(orderId);
        case (#bid) #bid(orderId);
      };
      switch (manageOrders(p, ? #orders([cancellation]), [], expectedSessionNumber)) {
        case (#ok _) #ok();
        case (#err(#SessionNumberMismatch x)) #err(#SessionNumberMismatch(x));
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };
    // ============= orders interface =============

    // ============ history interface =============
    public func getDepositHistory(p : Principal, assetId : ?AssetId) : Iter.Iter<T.DepositHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      var iter = Vec.valsRev(userInfo.depositHistory);
      switch (assetId) {
        case (?aid) Iter.filter<T.DepositHistoryItem>(iter, func x = x.2 == aid);
        case (_) iter;
      };
    };

    public func getTransactionHistory(p : Principal, assetId : ?AssetId) : Iter.Iter<T.TransactionHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      var iter = Vec.valsRev(userInfo.transactionHistory);
      switch (assetId) {
        case (?aid) Iter.filter<T.TransactionHistoryItem>(iter, func x = x.3 == aid);
        case (_) iter;
      };
    };

    public func getPriceHistory(assetId : ?AssetId) : Iter.Iter<T.PriceHistoryItem> {
      var iter = Vec.valsRev(assets.history);
      switch (assetId) {
        case (?aid) Iter.filter<T.PriceHistoryItem>(iter, func x = x.2 == aid);
        case (_) iter;
      };
    };
    // ============ history interface =============

    // ============= system interface =============
    public func share() : T.StableDataV6 = {
      assets = Vec.map<T.AssetInfo, T.StableAssetInfoV2>(
        assets.assets,
        func(x) = {
          lastRate = x.lastRate;
          lastProcessingInstructions = x.lastProcessingInstructions;
        },
      );
      orders = {
        globalCounter = orders.ordersCounter;
        fulfilledCounter = orders.fulfilledCounter;
      };
      quoteToken = {
        totalProcessedVolume = orders.totalQuoteVolumeProcessed;
        surplus = credits.quoteSurplus;
      };
      sessions = { counter = sessionsCounter; history = assets.history };
      users = {
        registry = {
          tree = (
            func() : RBTree.Tree<Principal, T.StableUserInfoV4> {
              let stableUsers = RBTree.RBTree<Principal, T.StableUserInfoV4>(Principal.compare);
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
                    depositHistory = u.depositHistory;
                    transactionHistory = u.transactionHistory;
                  },
                );
              };
              stableUsers.share();
            }
          )();
          size = users.usersAmount;
        };
        participantsArchive = {
          tree = users.participantsArchive.share();
          size = users.participantsArchiveSize;
        };
        accountsAmount = credits.accountsAmount;
      };
    };

    public func unshare(data : T.StableDataV6) {
      assets.assets := Vec.map<T.StableAssetInfoV2, T.AssetInfo>(
        data.assets,
        func(x) = {
          asks = { var queue = null; var size = 0; var totalVolume = 0 };
          bids = { var queue = null; var size = 0; var totalVolume = 0 };
          var lastRate = x.lastRate;
          var lastProcessingInstructions = x.lastProcessingInstructions;
          var sessionsCounter = data.sessions.counter;
        },
      );

      orders.ordersCounter := data.orders.globalCounter;
      orders.fulfilledCounter := data.orders.fulfilledCounter;

      orders.totalQuoteVolumeProcessed := data.quoteToken.totalProcessedVolume;
      credits.quoteSurplus := data.quoteToken.surplus;

      sessionsCounter := data.sessions.counter;
      assets.history := data.sessions.history;

      users.usersAmount := data.users.registry.size;
      let ud = RBTree.RBTree<Principal, T.StableUserInfoV4>(Principal.compare);
      ud.unshare(data.users.registry.tree);
      for ((p, u) in ud.entries()) {
        let userData : UserInfo = {
          asks = {
            var map = null;
          };
          bids = {
            var map = null;
          };
          var credits = u.credits;
          var depositHistory = u.depositHistory;
          var transactionHistory = u.transactionHistory;
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

      users.participantsArchive.unshare(data.users.participantsArchive.tree);
      users.participantsArchiveSize := data.users.participantsArchive.size;

      credits.accountsAmount := data.users.accountsAmount;

    };
    // ============= system interface =============
  };

};
