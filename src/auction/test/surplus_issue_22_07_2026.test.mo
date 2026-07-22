import Nat "mo:core/Nat";
import Prim "mo:prim";

import { init; createFt; generateUsers } "./test.util";

do {
  Prim.debugPrint("surplus issue test 22.07.2026 ...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let users : [Principal] = generateUsers(4);

  let dealVolume : Nat = 5_000_000_000_000_000_000_000;

  for (user in users.values()) {
    ignore auction.appendCredit(user, 0, 5_000_000_000_000_000_000_000_000_000);
    ignore auction.appendCredit(user, 1, 5_000_000_000_000_000_000_000_000_000);
  };

  ignore auction.placeOrder(users[0], #bid, 1, #delayed, dealVolume / 3, 1_000.0, null);
  ignore auction.placeOrder(users[1], #bid, 1, #delayed, dealVolume / 3, 1_000.0, null);
  ignore auction.placeOrder(users[2], #bid, 1, #delayed, dealVolume / 3, 1_000.0, null);

  ignore auction.placeOrder(users[3], #ask, 1, #delayed, dealVolume, 1_000.0, null);

  auction.processAsset(1);

  // expect assertion quoteSurplus >= 0 to not be failed
};
