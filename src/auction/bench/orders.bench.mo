import Array "mo:core/Array";
import Bench "mo:bench-helper";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Prim "mo:prim";
import Principal "mo:core/Principal";

import Auction "../src/lib";
import AuctionRuntime "../src/runtime";

module {
  func principalFromNat(n : Nat) : Principal {
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
  };

  public func init() : Bench.V1 {
    let schema : Bench.Schema = {
      name = "Managing orders";
      description = "Place/cancel many asks/bids in one atomic call. In this test asset does not have any additional orders set";
      rows = [
        "Place N bids (asc)",
        "Place N bids (desc)",
        "Cancel N bids one by one (asc)",
        "Cancel N bids one by one (desc)",
        "Cancel all N bids at once",
        "Cancel all N bids at once, filter by asset",
        "Replace N bids one by one (asc)",
        "Replace N bids one by one (desc)",
        "Cancel all + place N bids (asc)",
        "Cancel all + place N bids (desc)",
      ];
      cols = [
        "10",
        "50",
        "100",
        "500",
        "1000",
      ];
    };

    type Env = (Auction.Auction, AuctionRuntime.AuctionRuntime, ?Auction.CancellationAction, [Auction.PlaceOrderAction]);

    let user : Principal = principalFromNat(789);
    let env : [Env] = Array.tabulate<Env>(
      schema.rows.size() * schema.cols.size(),
      func(i) {
        let a = Auction.new(
          0,
          {
            volumeStepLog10 = 0;
            minVolumeSteps = 0;
            priceMaxDigits = 5;
          },
        );
        let runtime = AuctionRuntime.AuctionRuntime(
          a,
          {
            minAskVolume = func(_, _) = 0;
            performanceCounter = Prim.performanceCounter;
          },
        );
        a.registerAssets(2);
        let row : Nat = i % schema.rows.size();
        let col : Nat = i / schema.rows.size();

        let ?nActions = Nat.fromText(schema.cols[col]) else Prim.trap("Cannot parse nOrders");
        ignore a.appendCredit(user, 0, 5_000_000_000_000);

        let createBidsActions = Array.tabulate<Auction.PlaceOrderAction>(nActions, func(i) = #bid(1, #delayed, 100, 1.0 + Prim.intToFloat(i) / 1000.0));

        let (cancellation, placements) : (?Auction.CancellationAction, [Auction.PlaceOrderAction]) = switch (row) {
          case (0) (null, createBidsActions);
          case (1) (null, Array.reverse(createBidsActions));
          case (2) {
            let orderIds = switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok(_, oids)) oids;
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            ((?#orders(Array.tabulate<{ #ask : Auction.OrderId; #bid : Auction.OrderId }>(nActions, func(i) = #bid(orderIds[i].0)))), []);
          };
          case (3) {
            let orderIds = switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok(_, oids)) oids;
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            ((?#orders(Array.tabulate<{ #ask : Auction.OrderId; #bid : Auction.OrderId }>(nActions, func(i) = #bid(orderIds[nActions - 1 - i].0)))), []);
          };
          case (4) {
            switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok _) ();
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            (?#all(null), []);
          };
          case (5) {
            switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok _) ();
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            (?#all(?[1]), []);
          };
          case (6) {
            let orderIds = switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok(_, oids)) oids;
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            ((?#orders(Array.tabulate<{ #ask : Auction.OrderId; #bid : Auction.OrderId }>(nActions, func(i) = #bid(orderIds[i].0)))), createBidsActions);
          };
          case (7) {
            let orderIds = switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok(_, oids)) oids;
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            ((?#orders(Array.tabulate<{ #ask : Auction.OrderId; #bid : Auction.OrderId }>(nActions, func(i) = #bid(orderIds[nActions - 1 - i].0)))), Array.reverse(createBidsActions));
          };
          case (8) {
            switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok _) ();
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            (?#all(null), createBidsActions);
          };
          case (9) {
            switch (a.manageOrders(user, null, createBidsActions, null, runtime)) {
              case (#ok _) ();
              case (_) Prim.trap("Cannot prepare N set orders");
            };
            (?#all(null), Array.reverse(createBidsActions));
          };
          case (_) Prim.trap("Unknown row");
        };
        (a, runtime, cancellation, placements);
      },
    );

    Bench.V1(
      schema,
      func(ri : Nat, ci : Nat) {
        let (auction, runtime, cancellation, placements) = env[ci * schema.rows.size() + ri];
        let res = auction.manageOrders(user, cancellation, placements, null, runtime);
        switch (res) {
          case (#ok _) ();
          case (#err _) Prim.trap("Actions failed");
        };
      },
    );
  };
};
