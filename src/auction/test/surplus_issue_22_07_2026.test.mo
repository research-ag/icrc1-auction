import Nat "mo:core/Nat";
import Prim "mo:prim";

import Auction "../src/lib";

import { init; createFt; generateUsers } "./test.util";

// This issue happens because of float precision error.

// import Array "mo:core/Array";
// import { floatToInt; intToFloat; floatFloor } "mo:prim";

//  Array.map<Nat, Int>([
//  4_999_999_999_999_999_998,
//  1_666_666_666_666_666_666
// ], func (volume) {
//  let price = 1_000_000.0;
//  let fVolume = intToFloat(volume);
//  let denominated = fVolume * price;
//  floatToInt(denominated);
// });
// =>
// [5_000_000_000_000_000_452_984_832, 1_666_666_666_666_666_638_704_640]
// see that values were drifted in a different ways, and now auction pays bidder more than it takes out from askers
// https://embed.smartcontracts.org/motoko/g/FK6mnf2Kx8ezkHNZUjicMNZMBHQhjErqRqnige6nF46qTDprXydsYobV9zR7PyUX4w7nfYshLQDryzsjZUqSkEeESMj2aPef2A6Nv38NXuoji78AnENqJxhSqn9X1qcjj6Z3sWUDqxi2VqpjnMjukyTo3xkUVtAnjVC5Yq8BbNhyPqDZB1HXmhvd2SUTSi98vr4TCYsrS2SsV8CN2bmHvenw5WFCnFVBk6EUDRheQ9a3LPJ62S9yw6giYjSVyDS2inwfM?lines=13
do {
  Prim.debugPrint("surplus issue test 22.07.2026 ...");

  let (auction, runtime, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let users : [Principal] = generateUsers(4);

  for (user in users.values()) {
    ignore auction.appendCredit(user, 0, 5_000_000_000_000_000_000_000_000_000);
    ignore auction.appendCredit(user, 1, 5_000_000_000_000_000_000_000_000_000);
  };

  ignore auction.placeOrder(users[0], #bid, 1, #delayed, 1_666_666_666_666_666_666, 1_000_000.0, null, runtime);
  ignore auction.placeOrder(users[1], #bid, 1, #delayed, 1_666_666_666_666_666_666, 1_000_000.0, null, runtime);
  ignore auction.placeOrder(users[2], #bid, 1, #delayed, 1_666_666_666_666_666_666, 1_000_000.0, null, runtime);

  ignore auction.placeOrder(users[3], #ask, 1, #delayed, 5_000_000_000_000_000_000, 1_000_000.0, null, runtime);

  auction.processAsset(1, runtime);

  // expect assertion quoteSurplus >= 0 to not be failed
};
