import Nat "mo:core/Nat";
import Prim "mo:prim";

import AssetsStorage "../src/assets_storage";
import Auction "../src/lib";
import AuctionRuntime "../src/runtime";

import { init; createFt; generateUsers } "./test.util";

do {
  Prim.debugPrint("surplus issue test 19.08.2026 ...");

  let (auction, runtime, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let users : [Principal] = generateUsers(4);

  for (user in users.values()) {
    ignore auction.appendCredit(user, 0, 5_000_000_000_000_000_000_000_000_000);
    ignore auction.appendCredit(user, 1, 5_000_000_000_000_000_000_000_000_000);
  };

  let dealVolume : Nat = 5_000_000_000_000_000_000;

  ignore auction.placeOrder(users[0], #bid, 1, #delayed, 50_000_000_000_000_000_000, 1_000.0, null, runtime);

  ignore auction.placeOrder(users[1], #ask, 1, #delayed, 16_666_666_666_666_666_666, 1_000.0, null, runtime);
  ignore auction.placeOrder(users[2], #ask, 1, #delayed, 16_666_666_666_666_666_666, 1_000.0, null, runtime);
  ignore auction.placeOrder(users[3], #ask, 1, #delayed, 16_666_666_666_666_666_666, 1_000.0, null, runtime);

  auction.processAsset(1, runtime);

  // expect assertion quoteSurplus >= 0 to not be failed
};
