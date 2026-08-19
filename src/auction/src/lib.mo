/// A module which implements auction functionality for various trading pairs against quote fungible token
///
/// Copyright: 2023-2026 MR Research AG
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
import DecimalNat "mo:safe-financial-math/DecimalNat";

import Account "./account";
import AuctionRuntime "./runtime";
import AssetOrderBook "./asset_order_book";
import Asset "./asset";
import AssetsStorage "./assets_storage";
import C "./constants";
import E "./encryption";
import User "./user";
import UsersStorage "./users_storage";
import Processor "./auction_processor";
import T "./types";

module {

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  public type OrderBookType = T.OrderBookType;
  public type Order = T.Order;
  public type EncryptedOrderBook = T.EncryptedOrderBook;
  public type CreditInfo = T.CreditInfo;
  public type User = T.User;
  public type UserSettings = T.UserSettings;
  public type DepositHistoryItem = T.DepositHistoryItem;
  public type TransactionHistoryItem = T.TransactionHistoryItem;
  public type PriceHistoryItem = T.PriceHistoryItem;

  public type CancellationAction = T.CancellationAction;
  public type PlaceOrderAction = T.PlaceOrderAction;

  public type CancellationResult = T.CancellationResult;
  public type PlaceOrderResult = T.PlaceOrderResult;

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

  public type ManageOrdersError = T.OrderManagementError or {
    #UnknownPrincipal;
  };
  public type CancelOrderError = T.InternalCancelOrderError or {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
  };
  public type PlaceOrderError = T.InternalPlaceOrderError or {
    #AccountRevisionMismatch;
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  public type Auction = T.Auction;

  public func new(
    quoteAssetId : AssetId,
    settings : T.AuctionSettings,
  ) : Auction = {
    quoteAssetId;
    settings;
    assets = AssetsStorage.empty();
    users = UsersStorage.empty();
    var ordersCounter = 0;
    var sessionsCounter = 0;
  };

  // ============= assets interface =============
  public func getAssetSessionNumber(self : Auction, assetId : AssetId) : Nat = if (assetId == self.quoteAssetId) {
    self.sessionsCounter;
  } else {
    self.assets.getAsset(assetId).sessionsCounter;
  };

  public func registerAssets(self : Auction, n : Nat) = self.assets.register(n, self.sessionsCounter);

  public func nDarkOrderBooks(self : Auction, assetId : AssetId) : Nat {
    let assetInfo = self.assets.getAsset(assetId);
    assetInfo.darkOrderBooks.encrypted.size();
  };

  public func decryptDarkOrderBooks(self : Auction, assetId : AssetId, cryptoCanisterId : Principal, vetKey : Blob) : async* () {
    let assetInfo = self.assets.getAsset(assetId);
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

  public func processAsset(self : Auction, assetId : AssetId, runtime : AuctionRuntime.AuctionRuntime) {
    if (assetId == self.quoteAssetId) return;
    let startInstructions = runtime.runtimeSettings.performanceCounter(0);
    let assetInfo = self.assets.getAsset(assetId);
    let (encAsks, encBids) = runtime.processDarkOrderBooks(assetId, assetInfo);
    let asks = runtime.asks.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = encAsks }));
    let bids = runtime.bids.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = encBids }));
    let (price, volume) = Processor.clearAuction(asks, bids);
    if (volume > 0) {
      let { quoteSurplus } = Processor.processAuction(self.sessionsCounter, asks, bids, price, volume);
      if (quoteSurplus > 0) {
        self.users.quoteSurplus += quoteSurplus;
      };
      assetInfo.lastRate := price.toFloat();
    };
    self.assets.pushToHistory(#delayed, (Prim.time(), self.sessionsCounter, assetId, volume, price.toFloat()));
    assetInfo.lastProcessingInstructions := Nat64.toNat(runtime.runtimeSettings.performanceCounter(0) - startInstructions);
    assetInfo.sessionsCounter := self.sessionsCounter + 1;
  };

  public func orderBookInfo(self : Auction, assetId : AssetId, runtime : AuctionRuntime.AuctionRuntime) : OrderBookInfo {
    let assetInfo = self.assets.getAsset(assetId);
    let asksOrderBook = runtime.asks.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = null }));
    let bidsOrderBook = runtime.bids.createOrderBookExecutionService(assetInfo, #combined({ encryptedOrdersQueue = null }));
    let (price, volume) = Processor.clearAuction(asksOrderBook, bidsOrderBook);
    {
      clearing = if (volume > 0) {
        #match({ price = price.toFloat(); volume });
      } else {
        #noMatch;
      };
      maxBidPrice = bidsOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price.toFloat());
      minAskPrice = asksOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price.toFloat());
      totalBidVolume = bidsOrderBook.totalVolume();
      totalAskVolume = asksOrderBook.totalVolume();
    };
  };

  public func immediateOrderBookInfo(self : Auction, assetId : AssetId, runtime : AuctionRuntime.AuctionRuntime) : ImmediateOrderBookInfo {
    let assetInfo = self.assets.getAsset(assetId);
    let asksOrderBook = runtime.asks.createOrderBookExecutionService(assetInfo, #immediate);
    let bidsOrderBook = runtime.bids.createOrderBookExecutionService(assetInfo, #immediate);
    {
      maxBidPrice = bidsOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price.toFloat());
      minAskPrice = asksOrderBook.nextOrder() |> Option.map<(?T.OrderId, T.Order), Float>(_, func(b) = b.1.price.toFloat());
      totalBidVolume = bidsOrderBook.totalVolume();
      totalAskVolume = asksOrderBook.totalVolume();
    };
  };
  // ============= assets interface =============

  // ============= credits interface ============
  public func getCredit(self : Auction, p : Principal, assetId : AssetId) : CreditInfo = switch (self.users.get(p)) {
    case (null) ({ total = 0; locked = 0; available = 0 });
    case (?u) u.creditInfo(assetId);
  };

  public func getCredits(self : Auction, p : Principal) : [(AssetId, CreditInfo)] = switch (self.users.get(p)) {
    case (null) [];
    case (?u) u.creditInfoAll();
  };

  public func getAccountRevision(self : Auction, p : Principal) : Nat = switch (self.users.get(p)) {
    case (null) 0;
    case (?ui) ui.accountRevision;
  };

  public func getLoyaltyPoints(self : Auction, p : Principal) : Nat = switch (self.users.get(p)) {
    case (null) 0;
    case (?ui) ui.loyaltyPoints;
  };

  public func getTotalLoyaltyPointsSupply(self : Auction) : Nat {
    var res = 0;
    for (ui in self.users.usersList.values()) {
      res += ui.loyaltyPoints;
    };
    res;
  };

  public func appendCredit(self : Auction, p : Principal, assetId : AssetId, amount : Nat) : Nat {
    let user = self.users.getOrCreate(p);
    let acc = user.getOrCreateAccount(assetId);
    user.depositHistory.add((Prim.time(), #deposit, assetId, amount));
    user.accountRevision += 1;
    acc.appendCredit(amount);
  };

  public func deductCredit(self : Auction, p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> (), doneCallback : () -> ()), { #NoCredit }> {
    let ?user = self.users.get(p) else return #err(#NoCredit);
    let ?creditAcc = user.getAccount(assetId) else return #err(#NoCredit);
    switch (creditAcc.deductCredit(amount)) {
      case (true, balance) {
        user.accountRevision += 1;
        if (balance == 0 and user.deleteAccountIfEmpty(assetId)) {
          #ok(
            0,
            func() = ignore user.getOrCreateAccount(assetId).appendCredit(amount),
            func() = user.depositHistory.add((Prim.time(), #withdrawal, assetId, amount)),
          );
        } else {
          #ok(
            balance,
            func() = ignore creditAcc.appendCredit(amount),
            func() = user.depositHistory.add((Prim.time(), #withdrawal, assetId, amount)),
          );
        };
      };
      case (false, _) #err(#NoCredit);
    };
  };

  public func appendLoyaltyPoints(self : Auction, p : Principal, kind : { #wallet }) : Bool {
    let amount = switch (kind) {
      case (#wallet) C.LOYALTY_REWARD.WALLET_OPERATION;
    };
    let ?user = self.users.get(p) else return false;
    user.loyaltyPoints += amount;
    true;
  };
  // ============= credits interface ============

  // ============= orders interface =============
  public func getOrder(self : Auction, p : Principal, kind : { #ask; #bid }, orderId : OrderId) : ?T.Order = switch (self.users.get(p)) {
    case (null) null;
    case (?ui) ui.findOrder(kind, orderId);
  };

  public func getOrders(self : Auction, p : Principal, kind : { #ask; #bid }, assetId : ?AssetId) : [(OrderId, T.Order)] = switch (self.users.get(p)) {
    case (null) [];
    case (?ui) {
      var list = ui.getOrderBook(kind).map.entries();
      switch (assetId) {
        case (?aid) list := list.filter(func(_, o) = o.assetId == aid);
        case (_) {};
      };
      list.toArray();
    };
  };

  public func listAssetOrders(self : Auction, assetId : AssetId, kind : { #ask; #bid }, orderBookType : T.OrderBookType) : [(OrderId, T.Order)] {
    let orderBook = self.assets.getAsset(assetId).getOrderBook(kind, orderBookType);
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
    self : Auction,
    p : Principal,
    cancellations : ?T.CancellationAction,
    placements : [T.PlaceOrderAction],
    expectedAccountRevision : ?Nat,
    runtime : AuctionRuntime.AuctionRuntime,
  ) : R.Result<([CancellationResult], [PlaceOrderResult]), ManageOrdersError> {
    let ?userIdx = self.users.getIndex(p) else return #err(#UnknownPrincipal);
    runtime.manageOrders(p, userIdx, cancellations, placements, expectedAccountRevision);
  };

  public func manageDarkOrderBooks(self : Auction, p : Principal, args : [(T.AssetId, ?T.EncryptedOrderBook)], expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<[?T.EncryptedOrderBook], { #UnknownPrincipal; #AccountRevisionMismatch; #NoCredit }> {
    let ?userIdx = self.users.getIndex(p) else return #err(#UnknownPrincipal);
    runtime.manageDarkOrderBooks(p, userIdx, args, expectedAccountRevision);
  };

  public func placeOrder(self : Auction, p : Principal, kind : { #ask; #bid }, assetId : AssetId, orderBookType : OrderBookType, volume : Nat, price : Float, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<PlaceOrderResult, PlaceOrderError> {
    let placement = switch (kind) {
      case (#ask) #ask(assetId, orderBookType, volume, price);
      case (#bid) #bid(assetId, orderBookType, volume, price);
    };
    switch (manageOrders(self, p, null, [placement], expectedAccountRevision, runtime)) {
      case (#ok(_, x)) #ok(x[0]);
      case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
      case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
      case (#err(#placement { error })) #err(error);
      case (#err(#cancellation _)) Prim.trap("Can never happen");
    };
  };

  public func replaceOrder(self : Auction, p : Principal, kind : { #ask; #bid }, orderId : OrderId, volume : Nat, price : Float, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<PlaceOrderResult, ReplaceOrderError> {
    let (assetId, orderBookType) = switch (getOrder(self, p, kind, orderId)) {
      case (?o) (o.assetId, o.orderBookType);
      case (null) return #err(#UnknownOrder);
    };
    let (cancellation, placement) = switch (kind) {
      case (#ask) (#ask(orderId), #ask(assetId, orderBookType, volume, price));
      case (#bid) (#bid(orderId), #bid(assetId, orderBookType, volume, price));
    };
    switch (manageOrders(self, p, ?#orders([cancellation]), [placement], expectedAccountRevision, runtime)) {
      case (#ok(_, x)) #ok(x[0]);
      case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
      case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
      case (#err(#cancellation({ error }))) #err(error);
      case (#err(#placement({ error }))) #err(error);
    };
  };

  public func cancelOrder(self : Auction, p : Principal, kind : { #ask; #bid }, orderId : OrderId, expectedAccountRevision : ?Nat, runtime : AuctionRuntime.AuctionRuntime) : R.Result<CancellationResult, CancelOrderError> {
    let cancellation = switch (kind) {
      case (#ask) #ask(orderId);
      case (#bid) #bid(orderId);
    };
    switch (manageOrders(self, p, ?#orders([cancellation]), [], expectedAccountRevision, runtime)) {
      case (#ok(x, _)) #ok(x[0]);
      case (#err(#AccountRevisionMismatch)) #err(#AccountRevisionMismatch);
      case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
      case (#err(#cancellation({ error }))) #err(error);
      case (#err(#placement _)) Prim.trap("Can never happen");
    };
  };
  // ============= orders interface =============

  // ============ history interface =============
  public func getDepositHistory(self : Auction, p : Principal, assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.DepositHistoryItem> {
    let ?user = self.users.get(p) else return { next = func() = null };
    var iter = user.depositHistory
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

  public func getTransactionHistory(self : Auction, p : Principal, assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.TransactionHistoryItem> {
    let ?user = self.users.get(p) else return { next = func() = null };
    var iter = user.transactionHistory
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

  public func getPriceHistory(self : Auction, assetIds : [AssetId], order : { #asc; #desc }, skipEmpty : Bool) : Iter.Iter<T.PriceHistoryItem> {
    var iter = self.assets.historyIter(#delayed, order);
    if (assetIds.size() > 0) {
      iter := Iter.filter<T.PriceHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.2)));
    };
    if (skipEmpty) {
      iter := Iter.filter<T.PriceHistoryItem>(iter, func x = x.3 > 0);
    };
    iter;
  };

  public func getImmediatePriceHistory(self : Auction, assetIds : [AssetId], order : { #asc; #desc }) : Iter.Iter<T.PriceHistoryItem> {
    var iter = self.assets.historyIter(#immediate, order);
    if (assetIds.size() > 0) {
      iter := Iter.filter<T.PriceHistoryItem>(iter, func x = not Option.isNull(Array.find<Nat>(assetIds, func y = y == x.2)));
    };
    iter;
  };
  // ============ history interface =============

};
