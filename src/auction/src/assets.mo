import Iter "mo:base/Iter";
import Prim "mo:prim";

import Vec "mo:vector";

import AssetOrderBook "./asset_order_book";
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

    public func getOrderBook(asset : T.AssetInfo, kind : { #ask; #bid }, orderType : T.OrderType) : T.AssetOrderBook = (
      switch (kind) {
        case (#ask) asset.asks;
        case (#bid) asset.bids;
      }
    ) |> (
      switch (orderType) {
        case (#immediate) _.immediate;
        case (#delayed) _.delayed;
      }
    );

    public func deductOrderVolume(asset : T.AssetInfo, kind : { #ask; #bid }, order : T.Order, amount : Nat) {
      order.volume -= amount;
      AssetOrderBook.deductVolume(getOrderBook(asset, kind, order.orderType), amount);
    };

    public func putOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
      AssetOrderBook.insert(getOrderBook(asset, kind, order.orderType), orderId, order);
    };

    public func deleteOrder(asset : T.AssetInfo, kind : { #ask; #bid }, orderType : T.OrderType, orderId : T.OrderId) {
      let ?_ = AssetOrderBook.delete(getOrderBook(asset, kind, orderType), orderId) else Prim.trap("Cannot delete order from asset order book");
    };

    public func pushToHistory(item : T.PriceHistoryItem) {
      Vec.add(history, item);
    };

  };

};
