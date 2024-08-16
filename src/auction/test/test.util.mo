import Principal "mo:base/Principal";

import Auction "../src/lib";

module {

  public func init(quoteAssetId : Nat, volumeStepLog10 : Nat, minVolumeSteps : Nat) : (Auction.Auction, Principal) {
    let auction = Auction.Auction(
      quoteAssetId,
      {
        volumeStepLog10;
        minVolumeSteps;
        minAskVolume = func(_, _) = 20;
        performanceCounter = func(_) = 0;
      },
    );
    auction.registerAssets(quoteAssetId + 1);
    let user = Principal.fromText("rl3fy-hyflm-6r3qg-7nid5-lr6cp-ysfwh-xiqme-stgsq-bcga5-vnztf-mqe");
    (auction, user);
  };

  public func createFt(auction : Auction.Auction) : Nat {
    let id = auction.assets.nAssets();
    auction.registerAssets(1);
    id;
  };
};
