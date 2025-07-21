import Prim "mo:prim";

import { init; createFt } "./test.util";

do {
  Prim.debugPrint("should be able to place both bid and ask on the same asset...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft, 500_000_000);
  switch (auction.placeOrder(user, #bid, ft, 500_000, 250, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.placeOrder(user, #ask, ft, 2_000_000, 300, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft).size() == 1;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
};

do {
  Prim.debugPrint("should return error when placing ask with lower price than own bid price for the same asset...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft, 500_000_000);
  let orderId = switch (auction.placeOrder(user, #bid, ft, 500_000, 250, null)) {
    case (#ok id) id;
    case (_) { assert false; 0 };
  };
  switch (auction.placeOrder(user, #ask, ft, 2_000_000, 200, null)) {
    case (#err(#ConflictingOrder(#bid, oid))) assert oid == ?orderId;
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
  assert auction.getOrders(user, #ask, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should return error when placing bid with higher price than own ask price for the same asset...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft, 500_000_000);
  let orderId = switch (auction.placeOrder(user, #ask, ft, 2_000_000, 200, null)) {
    case (#ok id) id;
    case (_) { assert false; 0 };
  };
  switch (auction.placeOrder(user, #bid, ft, 500_000, 250, null)) {
    case (#err(#ConflictingOrder(#ask, oid))) assert oid == ?orderId;
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft).size() == 1;
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should return conflict error when placing both conflicting orders in one call");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft, 500_000_000);
  switch (
    auction.manageOrders(
      user,
      null,
      [
        #ask(ft, 2_000_000, 200),
        #bid(ft, 2_000, 250),
      ],
      null,
    )
  ) {
    case (#err(#placement({ index = 1; error = #ConflictingOrder(#ask, null) }))) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft).size() == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should place conflicting order if cancel old one in the same call");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  auction.processAsset(ft);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft, 500_000_000);
  let orderId = switch (auction.placeOrder(user, #ask, ft, 2_000_000, 200, null)) {
    case (#ok id) id;
    case (_) { assert false; 0 };
  };
  switch (
    auction.manageOrders(
      user,
      ?#orders([#ask(orderId)]),
      [#bid(ft, 2_000, 250)],
      null,
    )
  ) {
    case (#ok(_)) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft).size() == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
};

do {
  Prim.debugPrint("should be able to place various orders at once...");
  let (auction, user) = init(0, 3, 5);
  let ft1 = createFt(auction);
  let ft2 = createFt(auction);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft1, 500_000_000);
  ignore auction.appendCredit(user, ft2, 500_000_000);
  switch (
    auction.manageOrders(
      user,
      null,
      [
        #bid(ft1, 2_000, 250),
        #bid(ft1, 2_000, 300),
        #bid(ft2, 2_000, 250),
        #bid(ft2, 2_000, 300),
        #ask(ft1, 2_000_000, 350),
        #ask(ft1, 2_000_000, 400),
        #ask(ft2, 2_000_000, 350),
        #ask(ft2, 2_000_000, 400),
      ],
      null,
    )
  ) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft1).size() == 2;
  assert auction.getOrders(user, #bid, ?ft1).size() == 2;
  assert auction.getOrders(user, #ask, ?ft2).size() == 2;
  assert auction.getOrders(user, #bid, ?ft2).size() == 2;
  assert auction.getCredit(user, 0).available == 497_800_000;
  assert auction.getCredit(user, ft1).available == 496_000_000;
  assert auction.getCredit(user, ft2).available == 496_000_000;
};

do {
  Prim.debugPrint("should be able to cancel all orders at once...");
  let (auction, user) = init(0, 3, 5);
  let ft1 = createFt(auction);
  let ft2 = createFt(auction);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft1, 500_000_000);
  ignore auction.appendCredit(user, ft2, 500_000_000);
  switch (
    auction.manageOrders(
      user,
      null,
      [
        #bid(ft1, 2_000, 250),
        #bid(ft1, 2_000, 300),
        #bid(ft2, 2_000, 250),
        #bid(ft2, 2_000, 300),
        #ask(ft1, 2_000_000, 350),
        #ask(ft1, 2_000_000, 400),
        #ask(ft2, 2_000_000, 350),
        #ask(ft2, 2_000_000, 400),
      ],
      null,
    )
  ) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.manageOrders(user, ?#all(null), [], null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft1).size() == 0;
  assert auction.getOrders(user, #bid, ?ft1).size() == 0;
  assert auction.getOrders(user, #ask, ?ft2).size() == 0;
  assert auction.getOrders(user, #bid, ?ft2).size() == 0;
  assert auction.getCredit(user, 0).available == 500_000_000;
  assert auction.getCredit(user, ft1).available == 500_000_000;
  assert auction.getCredit(user, ft2).available == 500_000_000;
};

do {
  Prim.debugPrint("should be able to cancel all orders for for single asset at once...");
  let (auction, user) = init(0, 3, 5);
  let ft1 = createFt(auction);
  let ft2 = createFt(auction);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft1, 500_000_000);
  ignore auction.appendCredit(user, ft2, 500_000_000);
  switch (
    auction.manageOrders(
      user,
      null,
      [
        #bid(ft1, 2_000, 250),
        #bid(ft1, 2_000, 300),
        #bid(ft2, 2_000, 250),
        #bid(ft2, 2_000, 300),
        #ask(ft1, 2_000_000, 350),
        #ask(ft1, 2_000_000, 400),
        #ask(ft2, 2_000_000, 350),
        #ask(ft2, 2_000_000, 400),
      ],
      null,
    )
  ) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.manageOrders(user, ?#all(?[ft1]), [], null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft1).size() == 0;
  assert auction.getOrders(user, #bid, ?ft1).size() == 0;
  assert auction.getOrders(user, #ask, ?ft2).size() == 2;
  assert auction.getOrders(user, #bid, ?ft2).size() == 2;
  assert auction.getCredit(user, 0).available == 498_900_000;
  assert auction.getCredit(user, ft1).available == 500_000_000;
  assert auction.getCredit(user, ft2).available == 496_000_000;
};

do {
  Prim.debugPrint("should be able to cancel orders by enumerating id-s...");
  let (auction, user) = init(0, 3, 5);
  let ft1 = createFt(auction);
  let ft2 = createFt(auction);
  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user, ft1, 500_000_000);
  ignore auction.appendCredit(user, ft2, 500_000_000);
  let orderIds = switch (
    auction.manageOrders(
      user,
      null,
      [
        #bid(ft1, 2_000, 250),
        #bid(ft1, 2_000, 300),
        #bid(ft2, 2_000, 250),
        #bid(ft2, 2_000, 300),
        #ask(ft1, 2_000_000, 350),
        #ask(ft1, 2_000_000, 400),
        #ask(ft2, 2_000_000, 350),
        #ask(ft2, 2_000_000, 400),
      ],
      null,
    )
  ) {
    case (#ok(_, ids)) ids;
    case (_) {
      assert false;
      [];
    };
  };
  switch (auction.manageOrders(user, ?#orders([#bid(orderIds[1]), #ask(orderIds[4]), #ask(orderIds[5])]), [], null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #ask, ?ft1).size() == 0;
  assert auction.getOrders(user, #bid, ?ft1).size() == 1;
  assert auction.getOrders(user, #ask, ?ft2).size() == 2;
  assert auction.getOrders(user, #bid, ?ft2).size() == 2;
  assert auction.getCredit(user, 0).available == 498_400_000;
  assert auction.getCredit(user, ft1).available == 500_000_000;
  assert auction.getCredit(user, ft2).available == 496_000_000;
};
