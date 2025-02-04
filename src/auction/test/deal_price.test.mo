import Array "mo:base/Array";
import Prim "mo:prim";
import Principal "mo:base/Principal";

import { init; createFt } "./test.util";

do {
  Prim.debugPrint("should use correct price when orders are completely fulfilled and there are other unfulfilled orders...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);

  ignore auction.appendCredit(user, 0, 500_000_000);

  // should be fulfilled
  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_000_000, 1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled, too low bid
  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_000_000, 0.1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, ft, 500_000_000);

  // should be fulfilled
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 5_000_000, 0.8, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 5_000_000, 100, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  auction.processAsset(ft);

  let ?priceHistoryItem = auction.getPriceHistory([ft], #desc, false).next() else Prim.trap("");
  assert priceHistoryItem.3 == 5_000_000; // volume
  assert priceHistoryItem.4 == 0.8; // ask 0.8, bid 1
};

do {
  Prim.debugPrint("should use correct price when ask completely fulfilled and there are other unfulfilled orders...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);

  ignore auction.appendCredit(user, 0, 500_000_000);
  // should be fulfilled partially
  switch (auction.placeOrder(user, #bid, ft, #delayed, 6_010_000, 1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled, too low bid
  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_000_000, 0.1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, ft, 500_000_000);
  // should be fulfilled
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 5_000_000, 0.8, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 5_000_000, 100, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  auction.processAsset(ft);

  let ?priceHistoryItem = auction.getPriceHistory([ft], #desc, false).next() else Prim.trap("");
  assert priceHistoryItem.3 == 5_000_000; // volume
  assert priceHistoryItem.4 == 1.0; // ask 0.8, bid 1
};

do {
  Prim.debugPrint("should use correct price when bid completely fulfilled and there are other unfulfilled orders...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);

  ignore auction.appendCredit(user, 0, 500_000_000);
  // should be fulfilled partially
  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_010_000, 1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled, too low bid
  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_000_000, 0.1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, ft, 500_000_000);
  // should be fulfilled partially
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 6_000_000, 0.8, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  // should not be fulfilled
  switch (auction.placeOrder(user2, #ask, ft, #delayed, 5_000_000, 100, null)) {
    case (#ok _) ();
    case (_) assert false;
  };

  auction.processAsset(ft);

  let ?priceHistoryItem = auction.getPriceHistory([ft], #desc, false).next() else Prim.trap("");
  assert priceHistoryItem.3 == 5_010_000; // volume
  assert priceHistoryItem.4 == 0.8; // ask 0.8, bid 1
};

do {
  Prim.debugPrint("should have correct credits flow...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);

  let userExpectedCredits : [var Nat] = Array.init(2, 0);
  let user2ExpectedCredits : [var Nat] = Array.init(2, 0);
  func assertBalances(u : Principal, expectedCredits : [var Nat]) : () {
    let cr = auction.getCredits(u);
    if (cr[0].0 == 0) {
      assert cr[0].1.available == expectedCredits[0];
      assert cr[1].1.available == expectedCredits[1];
    } else {
      assert cr[0].1.available == expectedCredits[1];
      assert cr[1].1.available == expectedCredits[0];
    };
  };
  auction.processAsset(ft);

  ignore auction.appendCredit(user, 0, 500_000_000);
  userExpectedCredits[0] += 500_000_000;

  switch (auction.placeOrder(user, #bid, ft, #delayed, 5_000_000, 0.1, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  userExpectedCredits[0] -= 500_000;

  ignore auction.appendCredit(user, ft, 500_000_000);
  userExpectedCredits[1] += 500_000_000;

  switch (auction.placeOrder(user, #ask, ft, #delayed, 500_000, 26, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  userExpectedCredits[1] -= 500_000;

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, 0, 500_000_000);
  user2ExpectedCredits[0] += 500_000_000;
  ignore auction.appendCredit(user2, ft, 500_000_000);
  user2ExpectedCredits[1] += 500_000_000;

  switch (auction.placeOrder(user2, #ask, ft, #delayed, 980_000, 0.08, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  user2ExpectedCredits[1] -= 980_000;

  // check credits
  assertBalances(user, userExpectedCredits);
  assertBalances(user2, user2ExpectedCredits);

  auction.processAsset(ft);

  // note: user ask was not fulfilled because has too high price
  userExpectedCredits[0] += 98_000; // bid fulfilled part funds unlocked
  userExpectedCredits[0] -= 98_000; // bid fulfilled part funds charged (980_000 * 0.1)
  userExpectedCredits[1] += 980_000; // credited with bought token

  // note user2 [1] balance not changed: whole volume was locked and then charged
  user2ExpectedCredits[0] += 98_000; // credited from sold token (980_000 * 0.1)

  let ?priceHistoryItem = auction.getPriceHistory([ft], #desc, false).next() else Prim.trap("");
  assert priceHistoryItem.3 == 980_000;
  assert priceHistoryItem.4 == 0.1;

  assertBalances(user, userExpectedCredits);
  assertBalances(user2, user2ExpectedCredits);
};
