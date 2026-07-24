import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";

import Account "./account";
import T "./types";

module {

  public type User = T.User;

  public func new() : User = {
    asks = { var map = Map.empty() };
    bids = { var map = Map.empty() };
    var darkOrderBooks = Map.empty();
    var credits = Map.empty();
    var accountRevision = 0;
    var loyaltyPoints = 0;
    var depositHistory = List.empty<T.DepositHistoryItem>();
    var transactionHistory = List.empty<T.TransactionHistoryItem>();
    userSettings = {
      var pushNotificationsEnabled = false;
    };
  };

  public func getOrderBook(self : T.User, kind : { #ask; #bid }) : T.UserOrderBook = switch (kind) {
    case (#ask) self.asks;
    case (#bid) self.bids;
  };

  public func findOrder(self : T.User, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
    getOrderBook(self, kind).map.get(orderId);
  };

  public func putOrder(self : T.User, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
    getOrderBook(self, kind).map.add(orderId, order);
  };

  public func deleteOrder(self : T.User, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
    getOrderBook(self, kind).map.take(orderId);
  };

  public func findDarkOrderBook(self : T.User, asset : T.AssetId) : ?T.EncryptedOrderBook {
    self.darkOrderBooks.get(asset);
  };

  public func putDarkOrderBook(self : T.User, asset : T.AssetId, data : ?T.EncryptedOrderBook) : ?T.EncryptedOrderBook {
    switch (data) {
      case (?d) self.darkOrderBooks.swap(asset, d);
      case (null) self.darkOrderBooks.take(asset);
    };
  };

  public func getAccount(self : T.User, assetId : T.AssetId) : ?T.Account = self.credits.get(assetId);

  public func accountBalance(self : T.User, assetId : T.AssetId) : Nat = switch (getAccount(self, assetId)) {
    case (?acc) acc.balance();
    case (null) 0;
  };

  public func getOrCreateAccount(self : T.User, assetId : T.AssetId) : T.Account {
    switch (getAccount(self, assetId)) {
      case (?acc) acc;
      case (null) {
        let acc = { var credit = 0; var lockedCredit = 0 };
        self.credits.add(assetId, acc);
        acc;
      };
    };
  };

  public func deleteAccountIfEmpty(self : T.User, assetId : T.AssetId) : Bool {
    let ?acc = self.credits.get(assetId) else return false;
    if (acc.isEmpty()) {
      self.credits.remove(assetId);
      return true;
    };
    false;
  };

  public func creditInfo(self : T.User, assetId : T.AssetId) : T.CreditInfo = switch (getAccount(self, assetId)) {
    case (?acc) acc.creditInfo();
    case (null) ({ total = 0; locked = 0; available = 0 });
  };

  public func creditInfoAll(self : T.User) : [(T.AssetId, T.CreditInfo)] {
    self.credits.entries().map(func(aid, acc) = (aid, acc.creditInfo())).toArray();
  };

};
