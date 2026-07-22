import Nat "mo:core/Nat";
import Prim "mo:prim";

import { init; createFt; generateUsers } "./test.util";

do {
  Prim.debugPrint("regression test 22.07.2026 ...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let users : [Principal] = generateUsers(6);

  let dealVolume : Nat = 5_000_000_000_000_000_000_000;
  // bids with greater price and asks with lower price will be fulfilled
  let criticalPrice : Float = 1_000.0;

  for (i in Nat.range(0, 3)) {
    ignore auction.appendCredit(users[i], 0, 5_000_000_000_000_000_000_000_000_000);
    ignore auction.placeOrder(users[i], #bid, 1, #delayed, dealVolume / Nat.max(3, 1), criticalPrice + Prim.intToFloat((3 - i - 1)) * 0.1, null);

    ignore auction.appendCredit(users[3 + i], 1, 5_000_000_000_000_000_000_000_000_000);
    ignore auction.placeOrder(users[3 + i], #ask, 1, #delayed, dealVolume / Nat.max(1, 1), criticalPrice - Prim.intToFloat((1 - i - 1)) * 0.1, null);
  };
  assert auction.assets.getAsset(1).bids.delayed.size == 3;
  assert auction.assets.getAsset(1).asks.delayed.size == 3;
  auction.processAsset(1);
};
