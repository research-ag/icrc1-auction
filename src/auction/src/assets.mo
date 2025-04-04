import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import O "mo:base/Order";
import Prim "mo:prim";

import Vec "mo:vector";

import PriorityQueue "./priority_queue";
import T "./types";

module {

  public class Assets() {

    // asset info, index == assetId
    public var assets : Vec.Vector<T.AssetInfo> = Vec.new();
    // asset history
    public var history : Vec.Vector<T.PriceHistoryItem> = Vec.new();

    public func nAssets() : Nat = Vec.size(assets);

    public func getAsset(assetId : T.AssetId) : T.AssetInfo = Vec.get(assets, assetId);

    public func historyLength() : Nat = Vec.size(history);

    public func register(n : Nat, sessionsCounter : Nat) {
      for (i in Iter.range(1, n)) {
        (
          {
            bids = {
              var queue = List.nil();
              var size = 0;
              var totalVolume = 0;
            };
            asks = {
              var queue = List.nil();
              var size = 0;
              var totalVolume = 0;
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

    public func getOrderBook(asset : T.AssetInfo, kind : { #ask; #bid }) : T.AssetOrderBook = switch (kind) {
      case (#ask) asset.asks;
      case (#bid) asset.bids;
    };

    public func deductOrderVolume(asset : T.AssetInfo, kind : { #ask; #bid }, order : T.Order, amount : Nat) {
      let orderBook = getOrderBook(asset, kind);
      order.volume -= amount;
      orderBook.totalVolume -= amount;
    };

    public func putOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
      let orderBook = getOrderBook(asset, kind);
      orderBook.queue := PriorityQueue.insert(
        orderBook.queue,
        (orderId, order),
        switch (kind) {
          case (#ask) func(a : (T.OrderId, T.Order), b : (T.OrderId, T.Order)) : O.Order = Float.compare(b.1.price, a.1.price);
          case (#bid) func(a : (T.OrderId, T.Order), b : (T.OrderId, T.Order)) : O.Order = Float.compare(a.1.price, b.1.price);
        },
      );
      orderBook.size += 1;
      orderBook.totalVolume += order.volume;
    };

    public func deleteOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId) {
      let orderBook = getOrderBook(asset, kind);
      let (upd, oldValue) = PriorityQueue.findOneAndDelete<(T.OrderId, T.Order)>(orderBook.queue, func(id, _) = id == orderId);
      let ?(_, existingOrder) = oldValue else Prim.trap("Cannot delete order from asset order book");
      orderBook.queue := upd;
      orderBook.size -= 1;
      orderBook.totalVolume -= existingOrder.volume;
    };

    public func pushToHistory(item : T.PriceHistoryItem) {
      Vec.add(history, item);
    };

  };

};
