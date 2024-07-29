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
            var asks = List.nil();
            var askCounter = 0;
            var bids = List.nil();
            var bidCounter = 0;
            var lastRate = 0;
            var asksAmount = 0;
            var bidsAmount = 0;
            var lastProcessingInstructions = 0;
            var totalAskVolume = 0;
            var totalBidVolume = 0;
          } : T.AssetInfo
        )
        |> Vec.add(assets, _);
        assetsVecSize += 1;
      };
    };

  };

};
