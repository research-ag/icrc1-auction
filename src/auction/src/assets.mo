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

  public class Assets() {

    public let IMMEDIATE_BUFFER_CAPACITY = 65_536;

    // asset info, index == assetId
    public var assets : List.List<T.AssetInfo> = List.empty();
    // asset history
    public var history : {
      var immediate : CircularBuffer.CircularBuffer<T.PriceHistoryItem>;
      var delayed : List.List<T.PriceHistoryItem>;
    } = {
      var immediate = CircularBuffer.new<T.PriceHistoryItem>(IMMEDIATE_BUFFER_CAPACITY);
      var delayed = List.empty();
    };

    public func nAssets() : Nat = assets.size();

    public func getAsset(assetId : T.AssetId) : T.AssetInfo = assets.at(assetId);

    public func historyIter(orderBookType : T.OrderBookType, order : { #asc; #desc }) : Iter.Iter<T.PriceHistoryItem> {
      switch (orderBookType) {
        case (#immediate) {
          let (minIndex, nextIndex) = history.immediate.available();
          let (startI, endI, nextI) = switch (order) {
            case (#asc) (minIndex, Int.abs(Int.max(0, nextIndex - 1)), func(idx : Nat) : Nat = idx + 1);
            case (#desc) (Int.abs(Int.max(0, nextIndex - 1)), minIndex, func(idx : Nat) : Nat = Int.abs(idx - 1));
          };
          var i = startI;
          var stopped = false;
          object {
            public func next() : ?T.PriceHistoryItem {
              if (stopped) return null;
              let item = history.immediate.get(i);
              if (i == endI) {
                stopped := true;
              } else {
                i := nextI(i);
              };
              item;
            };
          };
        };
        case (#delayed) (
          switch (order) {
            case (#asc) history.delayed.values();
            case (#desc) history.delayed.reverseValues();
          }
        );
      };
    };

    public func historyLength(orderBookType : T.OrderBookType) : Nat = switch (orderBookType) {
      case (#immediate) Nat.min(IMMEDIATE_BUFFER_CAPACITY, history.immediate.pushesAmount());
      case (#delayed) history.delayed.size();
    };

    public func register(n : Nat, sessionsCounter : Nat) {
      for (_ in Nat.range(0, n)) {
        (
          {
            bids = {
              immediate = AssetOrderBook.nil(#bid);
              delayed = AssetOrderBook.nil(#bid);
            };
            asks = {
              immediate = AssetOrderBook.nil(#ask);
              delayed = AssetOrderBook.nil(#ask);
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
          } : T.AssetInfo
        )
        |> assets.add(_);
      };
    };

    public func getOrderBook(asset : T.AssetInfo, kind : { #ask; #bid }, orderBookType : T.OrderBookType) : T.AssetOrderBook = (
      switch (kind) {
        case (#ask) asset.asks;
        case (#bid) asset.bids;
      }
    ) |> (
      switch (orderBookType) {
        case (#immediate) _.immediate;
        case (#delayed) _.delayed;
      }
    );

    public func deductOrderVolume(asset : T.AssetInfo, kind : { #ask; #bid }, order : T.Order, amount : Nat) {
      order.volume -= amount;
      AssetOrderBook.deductVolume(getOrderBook(asset, kind, order.orderBookType), amount);
    };

    public func putOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) : Nat {
      AssetOrderBook.insert(getOrderBook(asset, kind, order.orderBookType), orderId, order);
    };

    public func deleteOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderBookType : T.OrderBookType, orderId : T.OrderId) {
      let ?_ = AssetOrderBook.delete(getOrderBook(asset, kind, orderBookType), orderId) else Prim.trap("Cannot delete order from asset order book");
    };

    public func putDarkOrderBook(asset : T.AssetInfo, user : Principal, data : ?T.EncryptedOrderBook) : ?T.EncryptedOrderBook {
      let oldValue = asset.darkOrderBooks.encrypted.get(user);
      switch (data) {
        case (?d) asset.darkOrderBooks.encrypted.add(user, d);
        case (null) asset.darkOrderBooks.encrypted.remove(user);
      };
      oldValue;
    };

    public func pushToHistory(orderBookType : T.OrderBookType, item : T.PriceHistoryItem) {
      switch (orderBookType) {
        case (#immediate) history.immediate.push(item);
        case (#delayed) history.delayed.add(item);
      };
    };

  };

};
