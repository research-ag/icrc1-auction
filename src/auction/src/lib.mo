/// A module which implements auction functionality for various trading pairs against quote fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

import Array "mo:base/Array";
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
import C "./constants";
import Credits "./credits";
import Orders "./orders";
import Users "./users";
import { processAuction; clearAuction } "./auction_processor";
import T "./types";

module {

  public func defaultStableDataV8() : T.StableDataV8 = {
    assets = Vec.new();
    orders = { globalCounter = 0 };
    quoteToken = { surplus = 0 };
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
  public type StableDataV8 = T.StableDataV8;
  public func migrateStableDataV8(data : StableDataV7) : StableDataV8 {
    let usersTree : RBTree.RBTree<Principal, T.StableUserInfoV6> = RBTree.RBTree(Principal.compare);
    for ((p, x) in RBTree.iter(data.users.registry.tree, #bwd)) {
      // remove withdraw rollback history items
      var list : List.List<(timestamp : Nat64, kind : { #deposit; #withdrawal; #withdrawalRollback }, assetId : AssetId, volume : Nat)> = null;
      for (item in Vec.vals(x.depositHistory)) {
        list := List.push(item, list);
      };
      var newList : List.List<(timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat)> = null;
      var skipNextWithdrawEvents : Nat = 0;
      for (item in List.toIter(list)) {
        switch (item.1, skipNextWithdrawEvents > 0) {
          case (#withdrawalRollback, _) skipNextWithdrawEvents += 1;
          case (#withdrawal, true) skipNextWithdrawEvents -= 1;
          case (#withdrawal, false) newList := List.push((item.0, #withdrawal, item.2, item.3), newList);
          case (#deposit, _) newList := List.push((item.0, #deposit, item.2, item.3), newList);
        };
      };
      let depositHistory : Vec.Vector<(timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat)> = Vec.new();
      for (item in List.toIter(newList)) {
        Vec.add(depositHistory, item);
      };
      usersTree.put(p, { x with depositHistory });
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

  public func defaultStableDataV7() : T.StableDataV7 = {
    assets = Vec.new();
    orders = { globalCounter = 0 };
    quoteToken = { surplus = 0 };
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
  public type StableDataV7 = T.StableDataV7;
  public func migrateStableDataV7(data : StableDataV6) : StableDataV7 {
    let usersTree : RBTree.RBTree<Principal, T.StableUserInfoV5> = RBTree.RBTree(Principal.compare);
    for ((p, x) in RBTree.iter(data.users.registry.tree, #bwd)) {
      usersTree.put(p, { x with loyaltyPoints = 0 });
    };
    {
      data with
      users = {
        data.users with registry = {
          data.users.registry with tree = usersTree.share()
        }
      };
      assets = Vec.map<T.StableAssetInfoV2, T.StableAssetInfoV3>(
        data.assets,
        func x = {
          x with
          totalExecutedVolumeBase = 0;
          totalExecutedVolumeQuote = 0;
          totalExecutedOrders = 0;
        },
      );
    };
  };

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
      usersTree.put(p, { x with transactionHistory = x.history; depositHistory = Vec.new<(timestamp : Nat64, kind : { #deposit; #withdrawal; #withdrawalRollback }, assetId : AssetId, volume : Nat)>() });
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

  public type CancellationResult = Orders.CancellationResult;

  public type IndicativeStats = {
    clearing : {
      #match : {
        price : Float;
        volume : Nat;
      };
      #noMatch : {
        minAskPrice : ?Float;
        maxBidPrice : ?Float;
      };
    };
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
    public func getAssetSessionNumber(assetId : AssetId) : Nat = if (assetId == quoteAssetId) {
      sessionsCounter;
    } else {
      assets.getAsset(assetId).sessionsCounter;
    };

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
      let asksOrderBook = orders.asks.createOrderBookService(assetInfo);
      let bidsOrderBook = orders.bids.createOrderBookService(assetInfo);
      switch (clearAuction(asksOrderBook, bidsOrderBook)) {
        case (?(price, volume)) ({
          clearing = #match({ price; volume });
          totalBidVolume = assetInfo.bids.totalVolume;
          totalAskVolume = assetInfo.asks.totalVolume;
        });
        case (null) ({
          clearing = #noMatch({
            maxBidPrice = List.get(bidsOrderBook.queue(), 0) |> Option.map<(T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
            minAskPrice = List.get(asksOrderBook.queue(), 0) |> Option.map<(T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
          });
          totalBidVolume = assetInfo.bids.totalVolume;
          totalAskVolume = assetInfo.asks.totalVolume;
        });
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

    public func getLoyaltyPoints(p : Principal) : Nat = switch (users.get(p)) {
      case (null) 0;
      case (?ui) ui.loyaltyPoints;
    };

    public func getTotalLoyaltyPointsSupply() : Nat {
      var res = 0;
      for ((_, ui) in users.users.entries()) {
        res += ui.loyaltyPoints;
      };
      res;
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = users.getOrCreate(p);
      let acc = credits.getOrCreate(userInfo, assetId);
      Vec.add<T.DepositHistoryItem>(userInfo.depositHistory, (Prim.time(), #deposit, assetId, amount));
      credits.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> (), doneCallback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = credits.getAccount(user, assetId) else return #err(#NoCredit);
      switch (credits.deductCredit(creditAcc, amount)) {
        case (true, balance) {
          if (balance == 0 and credits.deleteIfEmpty(user, assetId)) {
            #ok(
              0,
              func() = ignore credits.getOrCreate(user, assetId) |> credits.appendCredit(_, amount),
              func() = Vec.add<T.DepositHistoryItem>(user.depositHistory, (Prim.time(), #withdrawal, assetId, amount)),
            );
          } else {
            #ok(
              balance,
              func() = ignore credits.appendCredit(creditAcc, amount),
              func() = Vec.add<T.DepositHistoryItem>(user.depositHistory, (Prim.time(), #withdrawal, assetId, amount)),
            );
          };
        };
        case (false, _) #err(#NoCredit);
      };
    };

    public func appendLoyaltyPoints(p : Principal, kind : { #wallet }) : Bool {
      let amount = switch (kind) {
        case (#wallet) C.LOYALTY_REWARD.WALLET_OPERATION;
      };
      let ?userInfo = users.get(p) else return false;
      userInfo.loyaltyPoints += amount;
      true;
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

    public func getOrderBook(assetId : AssetId, kind : { #ask; #bid }) : [(OrderId, T.Order)] {
      let orderBook = assets.getAsset(assetId) |> assets.getOrderBook(_, kind);
      let queueIter = List.toIter(orderBook.queue);
      Array.tabulate<(OrderId, T.Order)>(
        orderBook.size,
        func(_) {
          let ?item = queueIter.next() else Prim.trap("Order book consistency failed");
          item;
        },
      );
    };

    public func manageOrders(
      p : Principal,
      cancellations : ?Orders.CancellationAction,
      placements : [Orders.PlaceOrderAction],
      expectedSessionNumber : ?Nat,
    ) : R.Result<([CancellationResult], [OrderId]), ManageOrdersError> {
      let ?userInfo = users.get(p) else return #err(#UnknownPrincipal);
      orders.manageOrders(p, userInfo, cancellations, placements, expectedSessionNumber);
    };

    public func placeOrder(p : Principal, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float, expectedSessionNumber : ?Nat) : R.Result<OrderId, PlaceOrderError> {
      let placement = switch (kind) {
        case (#ask) #ask(assetId, volume, price);
        case (#bid) #bid(assetId, volume, price);
      };
      switch (manageOrders(p, null, [placement], expectedSessionNumber)) {
        case (#ok(_, orderIds)) #ok(orderIds[0]);
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
      switch (manageOrders(p, ?#orders([cancellation]), [placement], expectedSessionNumber)) {
        case (#ok(_, orderIds)) #ok(orderIds[0]);
        case (#err(#SessionNumberMismatch x)) #err(#SessionNumberMismatch(x));
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement({ error }))) #err(error);
      };
    };

    public func cancelOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, expectedSessionNumber : ?Nat) : R.Result<CancellationResult, CancelOrderError> {
      let cancellation = switch (kind) {
        case (#ask) #ask(orderId);
        case (#bid) #bid(orderId);
      };
      switch (manageOrders(p, ?#orders([cancellation]), [], expectedSessionNumber)) {
        case (#ok(x, _)) #ok(x[0]);
        case (#err(#SessionNumberMismatch x)) #err(#SessionNumberMismatch(x));
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };
    // ============= orders interface =============

    // ============ history interface =============
    public func getDepositHistory(p : Principal, assetId : ?AssetId, order : { #asc; #desc }) : Iter.Iter<T.DepositHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      let iter = userInfo.depositHistory
      |> (
        switch (order) {
          case (#asc) Vec.vals(_);
          case (#desc) Vec.valsRev(_);
        }
      );
      switch (assetId) {
        case (?aid) Iter.filter<T.DepositHistoryItem>(iter, func x = x.2 == aid);
        case (_) iter;
      };
    };

    public func getTransactionHistory(p : Principal, assetId : ?AssetId, order : { #asc; #desc }) : Iter.Iter<T.TransactionHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      let iter = userInfo.transactionHistory
      |> (
        switch (order) {
          case (#asc) Vec.vals(_);
          case (#desc) Vec.valsRev(_);
        }
      );
      switch (assetId) {
        case (?aid) Iter.filter<T.TransactionHistoryItem>(iter, func x = x.3 == aid);
        case (_) iter;
      };
    };

    public func getPriceHistory(assetId : ?AssetId, order : { #asc; #desc }, skipEmpty : Bool) : Iter.Iter<T.PriceHistoryItem> {
      var iter = assets.history
      |> (
        switch (order) {
          case (#asc) Vec.vals(_);
          case (#desc) Vec.valsRev(_);
        }
      );
      switch (assetId) {
        case (?aid) iter := Iter.filter<T.PriceHistoryItem>(iter, func x = x.2 == aid);
        case (_) {};
      };
      if (skipEmpty) {
        iter := Iter.filter<T.PriceHistoryItem>(iter, func x = x.3 > 0);
      };
      iter;
    };
    // ============ history interface =============

    // ============= system interface =============
    public func share() : T.StableDataV8 = {
      assets = Vec.map<T.AssetInfo, T.StableAssetInfoV3>(
        assets.assets,
        func(x) = {
          lastRate = x.lastRate;
          lastProcessingInstructions = x.lastProcessingInstructions;
          totalExecutedVolumeBase = x.totalExecutedVolumeBase;
          totalExecutedVolumeQuote = x.totalExecutedVolumeQuote;
          totalExecutedOrders = x.totalExecutedOrders;
        },
      );
      orders = {
        globalCounter = orders.ordersCounter;
      };
      quoteToken = {
        surplus = credits.quoteSurplus;
      };
      sessions = { counter = sessionsCounter; history = assets.history };
      users = {
        registry = {
          tree = (
            func() : RBTree.Tree<Principal, T.StableUserInfoV6> {
              let stableUsers = RBTree.RBTree<Principal, T.StableUserInfoV6>(Principal.compare);
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
                    loyaltyPoints = u.loyaltyPoints;
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

    public func unshare(data : T.StableDataV8) {
      assets.assets := Vec.map<T.StableAssetInfoV3, T.AssetInfo>(
        data.assets,
        func(x) = {
          asks = { var queue = null; var size = 0; var totalVolume = 0 };
          bids = { var queue = null; var size = 0; var totalVolume = 0 };
          var lastRate = x.lastRate;
          var lastProcessingInstructions = x.lastProcessingInstructions;
          var totalExecutedVolumeBase = x.totalExecutedVolumeBase;
          var totalExecutedVolumeQuote = x.totalExecutedVolumeQuote;
          var totalExecutedOrders = x.totalExecutedOrders;
          var sessionsCounter = data.sessions.counter;
        },
      );

      orders.ordersCounter := data.orders.globalCounter;

      credits.quoteSurplus := data.quoteToken.surplus;

      sessionsCounter := data.sessions.counter;
      assets.history := data.sessions.history;

      users.usersAmount := data.users.registry.size;
      let ud = RBTree.RBTree<Principal, T.StableUserInfoV6>(Principal.compare);
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
          var loyaltyPoints = u.loyaltyPoints;
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
