import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";

import Auction "../src/lib";

module {

  public func init(quoteAssetId : Nat, volumeStepLog10 : Nat, minVolumeSteps : Nat) : (Auction.Auction, Principal) {
    let auction = Auction.Auction(
      quoteAssetId,
      {
        volumeStepLog10;
        minVolumeSteps;
        priceMaxDigits = 5;
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

  public func generateUsers(n : Nat) : [Principal] = Array.tabulate<Principal>(
    n,
    func(n : Nat) : Principal {
      let blobLength = 16;
      Principal.fromBlob(
        Array.tabulate<Nat8>(
          blobLength,
          func(i : Nat) : Nat8 {
            assert (i < blobLength);
            let shift : Nat = 8 * (blobLength - 1 - i);
            Nat8.fromIntWrap(n / 2 ** shift);
          },
        ).toBlob()
      );
    },
  );

};
