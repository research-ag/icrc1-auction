import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Map "mo:core/Map";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";

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

};
