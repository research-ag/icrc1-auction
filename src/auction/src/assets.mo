import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Prim "mo:prim";

import CircularBuffer "mo:mrr/CircularBuffer";
import Vec "mo:vector";

import AssetOrderBook "./asset_order_book";
import T "./types";

module {

  public class Assets() {

    public let IMMEDIATE_BUFFER_CAPACITY = 65_536;

    // asset info, index == assetId
    public var assets : Vec.Vector<T.AssetInfo> = Vec.new();
    // asset history
    public var history : {
      immediate : CircularBuffer.CircularBuffer<T.PriceHistoryItem>;
      var delayed : Vec.Vector<T.PriceHistoryItem>;
    } = {
      immediate = CircularBuffer.CircularBuffer<T.PriceHistoryItem>(IMMEDIATE_BUFFER_CAPACITY);
      var delayed = Vec.new();
    };

    public func nAssets() : Nat = Vec.size(assets);

    public func getAsset(assetId : T.AssetId) : T.AssetInfo = Vec.get(assets, assetId);

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
            case (#asc) Vec.vals(history.delayed);
            case (#desc) Vec.valsRev(history.delayed);
          }
        );
      };
    };

    public func historyLength(orderBookType : T.OrderBookType) : Nat = switch (orderBookType) {
      case (#immediate) Nat.min(IMMEDIATE_BUFFER_CAPACITY, history.immediate.pushesAmount());
      case (#delayed) Vec.size(history.delayed);
    };

    public func register(n : Nat, sessionsCounter : Nat) {
      for (i in Iter.range(1, n)) {
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
            var lastRate = 0;
            var lastProcessingInstructions = 0;
            var totalExecutedVolumeBase = 0;
            var totalExecutedVolumeQuote = 0;
            var totalExecutedOrders = 0;
            var sessionsCounter = sessionsCounter;
          } : T.AssetInfo
        )
        |> Vec.add(assets, _);
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

    public func pushToHistory(orderBookType : T.OrderBookType, item : T.PriceHistoryItem) {
      switch (orderBookType) {
        case (#immediate) history.immediate.push(item);
        case (#delayed) Vec.add(history.delayed, item);
      };
    };

  };

};
