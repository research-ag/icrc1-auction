import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";

import CircularBuffer "./models/circular_buffer";

import Asset "./asset";
import AssetOrderBook "./asset_order_book";
import T "./types";

module {

  public type AssetsStorage = T.AssetsStorage;

  public func empty() : AssetsStorage = {
    assets = List.empty();
    history = {
      immediate = CircularBuffer.new<T.PriceHistoryItem>(65_536);
      delayed = List.empty();
    };
  };

  public func nAssets(self : AssetsStorage) : Nat = self.assets.size();

  public func getAsset(self : AssetsStorage, assetId : T.AssetId) : T.Asset = self.assets.at(assetId);

  public func historyIter(self : AssetsStorage, orderBookType : T.OrderBookType, order : { #asc; #desc }) : Iter.Iter<T.PriceHistoryItem> {
    switch (orderBookType) {
      case (#immediate) {
        let (minIndex, nextIndex) = self.history.immediate.available();
        let (startI, endI, nextI) = switch (order) {
          case (#asc) (minIndex, Int.abs(Int.max(0, nextIndex - 1)), func(idx : Nat) : Nat = idx + 1);
          case (#desc) (Int.abs(Int.max(0, nextIndex - 1)), minIndex, func(idx : Nat) : Nat = Int.abs(idx - 1));
        };
        var i = startI;
        var stopped = false;
        object {
          public func next() : ?T.PriceHistoryItem {
            if (stopped) return null;
            let item = self.history.immediate.get(i);
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
          case (#asc) self.history.delayed.values();
          case (#desc) self.history.delayed.reverseValues();
        }
      );
    };
  };

  public func historyLength(self : AssetsStorage, orderBookType : T.OrderBookType) : Nat = switch (orderBookType) {
    case (#immediate) Nat.min(self.history.immediate.capacity, self.history.immediate.pushesAmount());
    case (#delayed) self.history.delayed.size();
  };

  public func register(self : AssetsStorage, n : Nat, sessionsCounter : Nat) {
    for (_ in Nat.range(0, n)) {
      self.assets.add(Asset.new(sessionsCounter));
    };
  };

  public func pushToHistory(self : AssetsStorage, orderBookType : T.OrderBookType, item : T.PriceHistoryItem) {
    switch (orderBookType) {
      case (#immediate) self.history.immediate.push(item);
      case (#delayed) self.history.delayed.add(item);
    };
  };

};
