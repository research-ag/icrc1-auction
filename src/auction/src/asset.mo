import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";

import CircularBuffer "./models/circular_buffer";

import AssetOrderBook "./asset_order_book";
import T "./types";

module {

  public type Asset = T.Asset;

  public func new(sessionsCounter : Nat) : Asset = {
    bids = {
      immediate = AssetOrderBook.empty(#bid);
      delayed = AssetOrderBook.empty(#bid);
    };
    asks = {
      immediate = AssetOrderBook.empty(#ask);
      delayed = AssetOrderBook.empty(#ask);
    };
    darkOrderBooks = {
      var encrypted = Map.empty();
      var decrypted = null;
    };
    var lastRate = 0;
    var lastImmediateRate = 0;
    var immediateExecutionsCounter = 0;
    var lastProcessingInstructions = 0;
    var totalExecutedVolumeBase = 0;
    var totalExecutedVolumeQuote = 0;
    var totalExecutedOrders = 0;
    var sessionsCounter = sessionsCounter;
  };

  public func getOrderBook(self : Asset, kind : { #ask; #bid }, orderBookType : T.OrderBookType) : T.AssetOrderBook = (
    switch (kind) {
      case (#ask) self.asks;
      case (#bid) self.bids;
    }
  ) |> (
    switch (orderBookType) {
      case (#immediate) _.immediate;
      case (#delayed) _.delayed;
    }
  );

  public func deductOrderVolume(self : Asset, kind : { #ask; #bid }, order : T.Order, amount : Nat) {
    order.volume -= amount;
    getOrderBook(self, kind, order.orderBookType).deductVolume(amount);
  };

  public func putOrder(self : Asset, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) : Nat {
    getOrderBook(self, kind, order.orderBookType).insert(orderId, order);
  };

  public func deleteOrder(self : Asset, kind : { #ask; #bid }, orderBookType : T.OrderBookType, orderId : T.OrderId) {
    let ?_ = getOrderBook(self, kind, orderBookType).delete(orderId) else Prim.trap("Cannot delete order from asset order book");
  };

  public func putDarkOrderBook(self : Asset, user : Principal, data : ?T.EncryptedOrderBook) : ?T.EncryptedOrderBook {
    let oldValue = self.darkOrderBooks.encrypted.get(user);
    switch (data) {
      case (?d) self.darkOrderBooks.encrypted.add(user, d);
      case (null) self.darkOrderBooks.encrypted.remove(user);
    };
    oldValue;
  };

};
