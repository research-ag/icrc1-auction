import Float "mo:base/Float";
import List "mo:base/List";
import O "mo:base/Order";
import Prim "mo:prim";

import Vec "mo:vector";

import PriorityQueue "./priority_queue";
import T "./types";

module {

  public class AssetsRepo() {

    // TODO find usages and replace with some interface

    // asset info, index == assetId
    public var assets : Vec.Vector<T.AssetInfo> = Vec.new();
    // asset history
    public var history : List.List<T.PriceHistoryItem> = null;

    public func register(n : Nat) {
      var assetsVecSize = Vec.size(assets);
      let newAmount = assetsVecSize + n;
      while (assetsVecSize < newAmount) {
        (
          {
            bids = {
              var queue = List.nil();
              var amount = 0;
              var totalVolume = 0;
            };
            asks = {
              var queue = List.nil();
              var amount = 0;
              var totalVolume = 0;
            };
            var lastRate = 0;
            var lastProcessingInstructions = 0;
          } : T.AssetInfo
        )
        |> Vec.add(assets, _);
        assetsVecSize += 1;
      };
    };

    public func putOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
      let orderBook = switch (kind) {
        case (#ask) asset.asks;
        case (#bid) asset.bids;
      };
      orderBook.queue := PriorityQueue.insert(
        orderBook.queue,
        (orderId, order),
        switch (kind) {
          case (#ask) func(a : (T.OrderId, T.Order), b : (T.OrderId, T.Order)) : O.Order = Float.compare(b.1.price, a.1.price);
          case (#bid) func(a : (T.OrderId, T.Order), b : (T.OrderId, T.Order)) : O.Order = Float.compare(a.1.price, b.1.price);
        },
      );
      orderBook.amount += 1;
      orderBook.totalVolume += order.volume;
    };

    // TODO check that nothing modifies totalVolume outside of this class
    public func popOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId) {
      let orderBook = switch (kind) {
        case (#ask) asset.asks;
        case (#bid) asset.bids;
      };
      let (upd, oldValue) = PriorityQueue.findOneAndDelete<(T.OrderId, T.Order)>(orderBook.queue, func(id, _) = id == orderId);
      let ?(_, existingOrder) = oldValue else Prim.trap("Cannot pop order from asset order book");
      orderBook.queue := upd;
      orderBook.amount -= 1;
      orderBook.totalVolume -= existingOrder.volume;
    };

  };

};
