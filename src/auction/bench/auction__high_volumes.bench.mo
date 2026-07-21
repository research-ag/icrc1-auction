import Array "mo:core/Array";
import Bench "mo:bench-helper";
import Blob "mo:core/Blob";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import Text "mo:core/Text";

import Auction "../src";

module {
  func principalFromNat(n : Nat) : Principal {
    let blobLength = 16;
    Principal.fromBlob(
      Blob.fromArray(
        Array.tabulate<Nat8>(
          blobLength,
          func(i : Nat) : Nat8 {
            assert (i < blobLength);
            let shift : Nat = 8 * (blobLength - 1 - i);
            Nat8.fromIntWrap(n / 2 ** shift);
          },
        )
      )
    );
  };

  public func init() : Bench.V1 {
    let schema : Bench.Schema = {
      name = "Auction processing (high volumes)";
      description = "Process a trading pair which has N placed orders and high token precision, e.g. deal volumes have 18+ digits";
      rows = [
        "Fulfil `0` asks, `0` bids",
        "Fulfil `1` ask, `1` bid",
        "Fulfil `N/2` asks, `1` bid",
        "Fulfil `1` ask, `N/2` bids",
        "Fulfil `N/2` asks, `N/2` bids",
      ];
      cols = [
        "10",
        "50",
        "100",
        "500",
        "1000",
        "5000",
      ];
    };

    // amount of asks/bids to be fulfilled
    func get_nAsks_nBids(nOrders : Nat, ri : Nat) : (Nat, Nat) = switch (ri) {
      case (0) (0, 0);
      case (1) (1, 1);
      case (2) (nOrders / 2, 1);
      case (3) (1, nOrders / 2);
      case (4) (nOrders / 2, nOrders / 2);
      case (_) Prim.trap("Cannot determine nAsks, nBids");
    };

    let users : [Principal] = Array.tabulate<Principal>(100_000, principalFromNat);
    let auctions : [Auction.Auction] = Array.tabulate<Auction.Auction>(
      schema.rows.size() * schema.cols.size(),
      func(i) {
        let a = Auction.Auction(
          0,
          {
            volumeStepLog10 = 0;
            minVolumeSteps = 0;
            minAskVolume = func(_) = 0;
            performanceCounter = Prim.performanceCounter;
            priceMaxDigits = 5;
          },
        );
        a.registerAssets(2);
        let row : Nat = i % schema.rows.size();
        let col : Nat = i / schema.rows.size();

        let ?nOrders = Nat.fromText(schema.cols[col]) else Prim.trap("Cannot parse nOrders");
        let (nAsks, nBids) = get_nAsks_nBids(nOrders, row);

        let dealVolume : Nat = 5_000_000_000_000_000_000_000;
        // bids with greater price and asks with lower price will be fulfilled
        let criticalPrice : Float = 1_000.0;

        for (i in Nat.range(0, nOrders / 2)) {
          let user = users[i];
          ignore a.appendCredit(user, 0, 5_000_000_000_000_000_000_000_000_000);
          ignore a.placeOrder(user, #bid, 1, #delayed, dealVolume / Nat.max(nBids, 1), criticalPrice + Prim.intToFloat((nBids - i - 1)) * 0.1, null);
        };
        for (i in Nat.range(0, nOrders / 2)) {
          let user = users[nOrders / 2 + i];
          ignore a.appendCredit(user, 1, 5_000_000_000_000_000_000_000_000_000);
          ignore a.placeOrder(user, #ask, 1, #delayed, dealVolume / Nat.max(nAsks, 1), criticalPrice - Prim.intToFloat((nAsks - i - 1)) * 0.1, null);
        };
        assert a.assets.getAsset(1).bids.delayed.size == nOrders / 2;
        assert a.assets.getAsset(1).asks.delayed.size == nOrders / 2;
        a;
      },
    );

    Bench.V1(
      schema,
      func(ri : Nat, ci : Nat) {
        let auction = auctions[ci * schema.rows.size() + ri];
        auction.processAsset(1);
      },
    );
  };
};
