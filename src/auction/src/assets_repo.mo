import List "mo:base/List";

import Vec "mo:vector";

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

  };

};
