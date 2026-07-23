/// A module which implements auction functionality for various trading pairs against quote fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

import Array "mo:core/Array";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Option "mo:core/Option";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import PureList "mo:core/pure/List";
import R "mo:core/Result";

import CircularBuffer "./models/circular_buffer";

import AuctionRuntime "./runtime";
import AssetOrderBook "./asset_order_book";
import Assets "./assets";
import C "./constants";
import Credits "./credits";
import E "./encryption";
import Orders "./orders";
import Users "./users";
import Processor "./auction_processor";
import T "./types";

module {

  // stable type
  public type AuctionNew = T.AuctionNew;

  public func new(
    quoteAssetId : AssetId,
    settings : T.AuctionSettings,
  ) : AuctionNew = {
    quoteAssetId;
    settings;
    users = List.empty();
  };

  public func defaultStableData() : T.StableDataV5 = {
    assets = List.empty();
    orders = { globalCounter = 0 };
    quoteToken = { surplus = 0 };
    sessions = {
      counter = 0;
      history = {
        immediate = CircularBuffer.new(1);
        delayed = List.empty<T.PriceHistoryItem>();
      };
    };
    users = {
      registry = {
        list = List.empty();
        lookup = Map.empty();
      };
      participantsArchive = {
        entries = [];
        size = 0;
      };
      accountsAmount = 0;
    };
  };
  public type StableDataV5 = T.StableDataV5;

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  public type OrderBookType = T.OrderBookType;
  public type Order = T.Order;
  public type EncryptedOrderBook = T.EncryptedOrderBook;
  public type CreditInfo = Credits.CreditInfo;
  public type UserInfo = T.UserInfo;
  public type UserSettings = T.UserSettings;
  public type DepositHistoryItem = T.DepositHistoryItem;
  public type TransactionHistoryItem = T.TransactionHistoryItem;
  public type PriceHistoryItem = T.PriceHistoryItem;

  public type CancellationAction = Orders.CancellationAction;
  public type PlaceOrderAction = Orders.PlaceOrderAction;

  public type CancellationResult = Orders.CancellationResult;
  public type PlaceOrderResult = Orders.PlaceOrderResult;

  public type PushNotification = T.PushNotification;

  public type OrderBookInfo = {
    clearing : {
      #match : {
        price : Float;
        volume : Nat;
      };
      #noMatch;
    };
    minAskPrice : ?Float;
    maxBidPrice : ?Float;
    totalBidVolume : Nat;
    totalAskVolume : Nat;
  };

  public type ImmediateOrderBookInfo = {
    minAskPrice : ?Float;
    maxBidPrice : ?Float;
    totalBidVolume : Nat;
    totalAskVolume : Nat;
  };

  public type ManageOrdersError = Orders.OrderManagementError or {
    #UnknownPrincipal;
  };
  public type CancelOrderError = Orders.InternalCancelOrderError or {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
  };
  public type PlaceOrderError = Orders.InternalPlaceOrderError or {
    #AccountRevisionMismatch;
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
    orders.executeImmediateOrderBooks := ?(
      func(assetId : T.AssetId, advantageFor : { #ask; #bid }) : [(price : Float, volume : Nat, fulfilledOrders : PureList.List<Processor.FulfilledOrder>)] {
        if (assetId == quoteAssetId) return [];
        let assetInfo = assets.getAsset(assetId);
        let ret = List.empty<(Float, Nat, PureList.List<Processor.FulfilledOrder>)>();
        let asks = orders.asks.createOrderBookExecutionService(assetInfo, #immediate);
        let bids = orders.bids.createOrderBookExecutionService(assetInfo, #immediate);
        label l while true {
          let (_, volume) = Processor.clearAuction(asks, bids);
          if (volume == 0) {
            break l;
          };
          let ?(_, { price }) = switch (advantageFor) {
            case (#ask) bids.nextOrder();
            case (#bid) asks.nextOrder();
          } else Prim.trap("Can never happen");
          let { quoteSurplus; fulfilledOrders } = Processor.processAuction(0, asks, bids, price, volume);
          if (quoteSurplus > 0) {
            credits.quoteSurplus += quoteSurplus;
          };
          ret.add((price, volume, fulfilledOrders));
          let executionsCounter = assetInfo.immediateExecutionsCounter;
          assetInfo.immediateExecutionsCounter += 1;
          assets.pushToHistory(#immediate, (Prim.time(), executionsCounter, assetId, volume, price));
          assetInfo.lastImmediateRate := price;
        };
        ret.toArray();
      }
    );

    // ============= assets interface =============
    public func getAssetSessionNumber(assetId : AssetId) : Nat = if (assetId == quoteAssetId) {
      sessionsCounter;
    } else {
      assets.getAsset(assetId).sessionsCounter;
    };

    public func registerAssets(n : Nat) = assets.register(n, sessionsCounter);

    public func nDarkOrderBooks(assetId : AssetId) : Nat {
      let assetInfo = assets.getAsset(assetId);
      assetInfo.darkOrderBooks.encrypted.size();
    };

    public func decryptDarkOrderBooks(assetId : AssetId, cryptoCanisterId : Principal, vetKey : Blob) : async* () {
      let assetInfo = assets.getAsset(assetId);
      let darkOrderBook = assetInfo.darkOrderBooks.encrypted.entries().toArray();
      if (darkOrderBook.size() == 0) {
        assetInfo.darkOrderBooks.decrypted := ?[];
        return;
      };
      let decrypted = await* E.decryptOrderBooks(
        cryptoCanisterId,
        vetKey,
        darkOrderBook |> Array.map<(Principal, T.EncryptedOrderBook), T.EncryptedOrderBook>(_, func(_, ob) = ob),
      );
      assetInfo.darkOrderBooks.decrypted := ?Array.tabulate<(Principal, [T.DecryptedOrderData])>(
        decrypted.size(),
        func(i) = (
          darkOrderBook[i].0,
          switch (decrypted[i]) {
            case (?d) d;
            case (null) [];
          },
        ),
      );
    };

    public func processAsset(assetId : AssetId) {
      if (assetId == quoteAssetId) return;
      let startInstructions = settings.performanceCounter(0);
      let assetInfo = assets.getAsset(assetId);
      let (encAsks, encBids) = orders.processDarkOrderBooks(assetId, assetInfo);
      let asks = orders.asks.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = encAsks }));
      let bids = orders.bids.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = encBids }));
      let (price, volume) = Processor.clearAuction(asks, bids);
      if (volume > 0) {
        let { quoteSurplus } = Processor.processAuction(sessionsCounter, asks, bids, price, volume);
        if (quoteSurplus > 0) {
          credits.quoteSurplus += quoteSurplus;
        };
        assetInfo.lastRate := price;
      };
      assets.pushToHistory(#delayed, (Prim.time(), sessionsCounter, assetId, volume, price));
      assetInfo.lastProcessingInstructions := Nat64.toNat(settings.performanceCounter(0) - startInstructions);
      assetInfo.sessionsCounter := sessionsCounter + 1;
    };

    public func orderBookInfo(assetId : AssetId) : OrderBookInfo {
      let assetInfo = assets.getAsset(assetId);
      let asksOrderBook = orders.asks.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = null }));
      let bidsOrderBook = orders.bids.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = null }));
      let (price, volume) = Processor.clearAuction(asksOrderBook, bidsOrderBook);
      {
        clearing = if (volume > 0) {
          #match({ price; volume });
        } else {
          #noMatch;
        };
        maxBidPrice = bidsOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
        minAskPrice = asksOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
        totalBidVolume = bidsOrderBook.totalVolume();
        totalAskVolume = asksOrderBook.totalVolume();
      };
    };

    public func immediateOrderBookInfo(assetId : AssetId) : ImmediateOrderBookInfo {
      let assetInfo = assets.getAsset(assetId);
      let asksOrderBook = orders.asks.createOrderBookExecutionService(assetInfo, #immediate);
      let bidsOrderBook = orders.bids.createOrderBookExecutionService(assetInfo, #immediate);
      {
        maxBidPrice = bidsOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
        minAskPrice = asksOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price);
        totalBidVolume = bidsOrderBook.totalVolume();
        totalAskVolume = asksOrderBook.totalVolume();
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

    public func getAccountRevision(p : Principal) : Nat = switch (users.get(p)) {
      case (null) 0;
      case (?ui) ui.accountRevision;
    };

    public func getLoyaltyPoints(p : Principal) : Nat = switch (users.get(p)) {
      case (null) 0;
      case (?ui) ui.loyaltyPoints;
    };

    public func getTotalLoyaltyPointsSupply() : Nat {
      var res = 0;
      for (ui in users.usersList.values()) {
        res += ui.loyaltyPoints;
      };
      res;
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = users.getOrCreate(p);
      let acc = credits.getOrCreate(userInfo, assetId);
      userInfo.depositHistory.add((Prim.time(), #deposit, assetId, amount));
      userInfo.accountRevision += 1;
      credits.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> (), doneCallback : () -> ()), { #NoCredit }> {
      let ?user = users.get(p) else return #err(#NoCredit);
      let ?creditAcc = credits.getAccount(user, assetId) else return #err(#NoCredit);
      switch (credits.deductCredit(creditAcc, amount)) {
        case (true, balance) {
          user.accountRevision += 1;
          if (balance == 0 and credits.deleteIfEmpty(user, assetId)) {
            #ok(
              0,
              func() = ignore credits.getOrCreate(user, assetId) |> credits.appendCredit(_, amount),
              func() = user.depositHistory.add((Prim.time(), #withdrawal, assetId, amount)),
            );
          } else {
            #ok(
              balance,
              func() = ignore credits.appendCredit(creditAcc, amount),
              func() = user.depositHistory.add((Prim.time(), #withdrawal, assetId, amount)),
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
        var list = users.getOrderBook(ui, kind).map.entries();
        switch (assetId) {
          case (?aid) list := list.filter(func(_, o) = o.assetId == aid);
          case (_) {};
        };
        list.toArray();
      };
    };

    public func listAssetOrders(assetId : AssetId, kind : { #ask; #bid }, orderBookType : T.OrderBookType) : [(OrderId, T.Order)] {
      let orderBook = assets.getAsset(assetId) |> assets.getOrderBook(_, kind, orderBookType);
      let queueIter = PureList.values(orderBook.queue);
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
      expectedAccountRevision : ?Nat,
      runtime : AuctionRuntime.AuctionRuntime,
    ) : R.Result<([CancellationResult], [PlaceOrderResult]), ManageOrdersError> {
      let ?userIdx = users.getIndex(p) else return #err(#UnknownPrincipal);
      orders.manageOrders(p, userIdx, cancellations, placements, expectedAccountRevision, runtime);
    };

    public func manageDarkOrderBooks(p : Principal, args : [(T.AssetId, ?T.EncryptedOrderBook)], expectedAccountRevision : ?Nat) : R.Result<[?T.EncryptedOrderBook], { #UnknownPrincipal; #AccountRevisionMismatch; #NoCredit }> {
      let ?userIdx = users.getIndex(p) else return #err(#UnknownPrincipal);
      orders.manageDarkOrderBooks(p, userIdx, args, expectedAccountRevision);
    };

    public func placeOrder(p : Principal, kind : { #ask; #bid }, assetId : AssetId, orderBookType : OrderBookType, volume : Nat, price : Float, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<PlaceOrderResult, PlaceOrderError> {
      let placement = switch (kind) {
        case (#ask) #ask(assetId, orderBookType, volume, price);
        case (#bid) #bid(assetId, orderBookType, volume, price);
      };
      switch (manageOrders(p, null, [placement], expectedAccountRevision, runtime)) {
        case (#ok(_, x)) #ok(x[0]);
        case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) #err(error);
        case (#err(#cancellation _)) Prim.trap("Can never happen");
      };
    };

    public func replaceOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<PlaceOrderResult, ReplaceOrderError> {
      let (assetId, orderBookType) = switch (getOrder(p, kind, orderId)) {
        case (?o) (o.assetId, o.orderBookType);
        case (null) return #err(#UnknownOrder);
      };
      let (cancellation, placement) = switch (kind) {
        case (#ask) (#ask(orderId), #ask(assetId, orderBookType, volume, price));
        case (#bid) (#bid(orderId), #bid(assetId, orderBookType, volume, price));
      };
      switch (manageOrders(p, ?#orders([cancellation]), [placement], expectedAccountRevision, runtime)) {
        case (#ok(_, x)) #ok(x[0]);
        case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement({ error }))) #err(error);
      };
    };

    public func cancelOrder(p : Principal, kind : { #ask; #bid }, orderId : OrderId, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<CancellationResult, CancelOrderError> {
      let cancellation = switch (kind) {
        case (#ask) #ask(orderId);
        case (#bid) #bid(orderId);
      };
      switch (manageOrders(p, ?#orders([cancellation]), [], expectedAccountRevision, runtime)) {
        case (#ok(x, _)) #ok(x[0]);
        case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };
    // ============= orders interface =============

    // ============ history interface =============
    public func getDepositHistory(p : Principal, assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.DepositHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      var iter = userInfo.depositHistory
      |> (
        switch (order) {
          case (#asc) List.values(_);
          case (#desc) List.reverseValues(_);
        }
      );
      if (assetIds.size() > 0) {
        iter := Iter.filter<T.DepositHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.2)));
      };
      iter;
    };

    public func getTransactionHistory(p : Principal, assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.TransactionHistoryItem> {
      let ?userInfo = users.get(p) else return { next = func() = null };
      var iter = userInfo.transactionHistory
      |> (
        switch (order) {
          case (#asc) List.values(_);
          case (#desc) List.reverseValues(_);
        }
      );
      if (assetIds.size() > 0) {
        iter := Iter.filter<T.TransactionHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.3)));
      };
      iter;
    };

    public func getPriceHistory(assetIds : [AssetId], order : { #asc; #desc }, skipEmpty : Bool) : Iter.Iter<T.PriceHistoryItem> {
      var iter = assets.historyIter(#delayed, order);
      if (assetIds.size() > 0) {
        iter := Iter.filter<T.PriceHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.2)));
      };
      if (skipEmpty) {
        iter := Iter.filter<T.PriceHistoryItem>(iter, func x = x.3 > 0);
      };
      iter;
    };

    public func getImmediatePriceHistory(assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.PriceHistoryItem> {
      var iter = assets.historyIter(#immediate, order);
      if (assetIds.size() > 0) {
        iter := Iter.filter<T.PriceHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.2)));
      };
      iter;
    };
    // ============ history interface =============

    // ============= system interface =============
    public func share() : T.StableDataV5 = {
      assets = assets.assets.map<T.AssetInfo, T.StableAssetInfoV3>(
        func(x) = {
          lastRate = x.lastRate;
          lastImmediateRate = x.lastImmediateRate;
          immediateExecutionsCounter = x.immediateExecutionsCounter;
          lastProcessingInstructions = x.lastProcessingInstructions;
          totalExecutedVolumeBase = x.totalExecutedVolumeBase;
          totalExecutedVolumeQuote = x.totalExecutedVolumeQuote;
          totalExecutedOrders = x.totalExecutedOrders;
        }
      );
      orders = {
        globalCounter = orders.ordersCounter;
      };
      quoteToken = {
        surplus = credits.quoteSurplus;
      };
      sessions = {
        counter = sessionsCounter;
        history = {
          immediate = assets.history.immediate;
          delayed = assets.history.delayed;
        };
      };
      users = {
        registry = {
          list = users.usersList;
          lookup = users.usersLookup;
        };
        participantsArchive = {
          entries = Map.entries(users.participantsArchive) |> Iter.toArray(_);
          size = users.participantsArchiveSize;
        };
        accountsAmount = credits.accountsAmount;
      };
    };

    public func unshare(data : T.StableDataV5) {
      assets.assets := data.assets.map<T.StableAssetInfoV3, T.AssetInfo>(
        func(x) = {
          asks = {
            delayed = AssetOrderBook.nil(#ask);
            immediate = AssetOrderBook.nil(#ask);
          };
          bids = {
            delayed = AssetOrderBook.nil(#bid);
            immediate = AssetOrderBook.nil(#bid);
          };
          darkOrderBooks = {
            var encrypted = Map.empty();
            var decrypted = null;
          };
          var lastRate = x.lastRate;
          var lastImmediateRate = x.lastImmediateRate;
          var immediateExecutionsCounter = x.immediateExecutionsCounter;
          var lastProcessingInstructions = x.lastProcessingInstructions;
          var totalExecutedVolumeBase = x.totalExecutedVolumeBase;
          var totalExecutedVolumeQuote = x.totalExecutedVolumeQuote;
          var totalExecutedOrders = x.totalExecutedOrders;
          var sessionsCounter = data.sessions.counter;
        }
      );

      orders.ordersCounter := data.orders.globalCounter;

      credits.quoteSurplus := data.quoteToken.surplus;

      sessionsCounter := data.sessions.counter;

      if (data.sessions.history.immediate.capacity == assets.IMMEDIATE_BUFFER_CAPACITY) {
        assets.history.immediate := data.sessions.history.immediate;
      };
      assets.history.delayed := data.sessions.history.delayed;

      for ((p, idx) in data.users.registry.lookup.entries()) {
        let u = data.users.registry.list.at(idx);
        let userData : UserInfo = {
          asks = {
            var map = Map.empty();
          };
          bids = {
            var map = Map.empty();
          };
          var darkOrderBooks = u.darkOrderBooks;
          var credits = u.credits;
          var accountRevision = u.accountRevision;
          var loyaltyPoints = u.loyaltyPoints;
          var depositHistory = u.depositHistory;
          var transactionHistory = u.transactionHistory;
          userSettings = {
            var pushNotificationsEnabled = u.userSettings.pushNotificationsEnabled;
          };
        };
        for ((oid, order) in u.asks.map.entries()) {
          users.putOrder(userData, #ask, oid, order);
          ignore assets.putOrder(assets.getAsset(order.assetId), #ask, oid, order);
        };
        for ((oid, order) in u.bids.map.entries()) {
          users.putOrder(userData, #bid, oid, order);
          ignore assets.putOrder(assets.getAsset(order.assetId), #bid, oid, order);
        };
        for ((assetId, data) in u.darkOrderBooks.entries()) {
          ignore assets.putDarkOrderBook(assets.getAsset(assetId), p, ?data);
        };
        let index = users.usersList.size();
        users.usersList.add(userData);
        users.usersLookup.add(p, index);
      };

      for ((p, entry) in data.users.participantsArchive.entries.values()) {
        Map.add(users.participantsArchive, Principal.compare, p, entry);
      };
      users.participantsArchiveSize := data.users.participantsArchive.size;

      credits.accountsAmount := data.users.accountsAmount;

    };
    // ============= system interface =============
  };

};
