import Prim "mo:prim";
import Principal "mo:base/Principal";

import { init; createFt } "./test.util";

do {
  Prim.debugPrint("should not be able to place bid on non-existent token...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = 123;
  let res = auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null);
  switch (res) {
    case (#err(#UnknownAsset)) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should not be able to place bid on quote token...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = 0;
  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null)) {
    case (#err(#UnknownAsset)) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should not be able to place bid with non-sufficient deposit...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = createFt(auction);
  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 1_000_000, null)) {
    case (#err(#NoCredit)) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should not be able to place bid with too low volume...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = createFt(auction);
  switch (auction.placeOrder(user, #bid, ft, #delayed, 20, 100, null)) {
    case (#err(#TooLowOrder)) ();
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should be able to place a bid...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = createFt(auction);
  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 1_000, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  let bids = auction.getOrders(user, #bid, ?ft);
  assert bids.size() == 1;
  assert bids[0].1.price == 1_000;
  assert bids[0].1.volume == 2_000;
  assert auction.getCredit(user, 0).available == 498_000_000;
};

do {
  Prim.debugPrint("should affect stats...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = createFt(auction);
  ignore auction.placeOrder(user, #bid, ft, #delayed, 2_000, 15_000, null);

  assert auction.assets.getAsset(ft).bids.delayed.size == 1;
  assert auction.assets.getAsset(ft).bids.delayed.totalVolume == 2000;

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 200_000_000, 15_000, null);
  auction.processAsset(ft);

  assert auction.getOrders(user, #bid, ?ft).size() == 0;
  assert auction.assets.getAsset(ft).bids.delayed.size == 0;
  assert auction.assets.getAsset(ft).bids.delayed.totalVolume == 0;
};

do {
  Prim.debugPrint("unfulfilled bids should affect deposit...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);

  let ft = createFt(auction);
  switch (auction.placeOrder(user, #bid, ft, #delayed, 1_000, 400_000, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.placeOrder(user, #bid, ft, #delayed, 1_000, 400_000, null)) {
    case (#err(#NoCredit)) ();
    case (_) assert false;
  };
};

do {
  Prim.debugPrint("should be able to place few bids on the same token...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);
  let ft = createFt(auction);

  assert auction.getCredit(user, 0).available == 500_000_000;
  ignore auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null);
  assert auction.getCredit(user, 0).available == 300_000_000;
  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 150_000, null)) {
    case (#ok _) ();
    case (_) assert false;
  };
  assert auction.getCredit(user, 0).available == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 2;
};

do {
  Prim.debugPrint("should not be able to place few bids on the same token with the same price...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);
  let ft = createFt(auction);

  assert auction.getCredit(user, 0).available == 500_000_000;
  let orderId = switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null)) {
    case (#ok(id, _)) id;
    case (_) { assert false; 0 };
  };
  assert auction.getCredit(user, 0).available == 300_000_000;
  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null)) {
    case (#err(#ConflictingOrder(#bid, oid))) assert oid == ?orderId;
    case (_) assert false;
  };
  assert auction.getCredit(user, 0).available == 300_000_000;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
};

do {
  Prim.debugPrint("should be able to replace a bid...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);
  let ft = createFt(auction);

  let orderId = switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 125_000, null)) {
    case (#ok(id, _)) id;
    case (_) { assert false; 0 };
  };
  assert auction.getCredit(user, 0).available == 250_000_000;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  let newOrderId = switch (auction.replaceOrder(user, #bid, orderId, 2_000, 250_000, null)) {
    case (#ok(id, _)) id;
    case (_) { assert false; 0 };
  };
  assert auction.getCredit(user, 0).available == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  switch (auction.replaceOrder(user, #bid, newOrderId, 2_000, 60_000, null)) {
    case (#ok _) {};
    case (_) assert false;
  };
  assert auction.getCredit(user, 0).available == 380_000_000;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
};

do {
  Prim.debugPrint("non-sufficient deposit should not cancel old bid when replacing...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);
  let ft = createFt(auction);

  let orderId = switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 125_000, null)) {
    case (#ok(id, _)) id;
    case (_) { assert false; 0 };
  };
  assert auction.getCredit(user, 0).available == 250_000_000;
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  switch (auction.replaceOrder(user, #bid, orderId, 2_000_000, 250_000_000, null)) {
    case (#err(#NoCredit)) ();
    case (_) assert false;
  };
  assert auction.getCredit(user, 0).available == 250_000_000;
  let bids = auction.getOrders(user, #bid, ?ft);
  assert bids.size() == 1;
  assert bids[0].0 == orderId;
  assert bids[0].1.price == 125_000;
  assert bids[0].1.volume == 2_000;
};

do {
  Prim.debugPrint("should fulfil the only bid...");
  let (auction, user) = init(0, 3, 5);
  ignore auction.appendCredit(user, 0, 500_000_000);
  let ft = createFt(auction);

  switch (auction.placeOrder(user, #bid, ft, #delayed, 2_000, 15_000, null)) {
    case (#ok _) {};
    case (_) assert false;
  };
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
  assert auction.getCredit(user, 0).available == 470_000_000;

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 200_000_000, 15_000, null);

  auction.processAsset(ft);

  // test that bid disappeared
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
  // test that tokens were decremented from deposit, credit added
  assert auction.getCredit(user, 0).available == 470_000_000;
  assert auction.getCredit(user, ft).available == 2_000;
  // check history
  let ?historyItem = auction.getTransactionHistory(user, [ft], #desc).next() else Prim.trap("");
  assert historyItem.1 == 0;
  assert historyItem.2 == #bid;
  assert historyItem.3 == ft;
  assert historyItem.4 == 2_000;
  assert historyItem.5 == 15_000;
};

do {
  Prim.debugPrint("should fulfil many bids at once...");
  let (auction, user) = init(0, 3, 5);
  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.appendCredit(user2, 0, 500_000_000);
  let ft1 = createFt(auction);
  let ft2 = createFt(auction);

  ignore auction.placeOrder(user, #bid, ft1, #delayed, 1_500, 100_000, null);
  ignore auction.placeOrder(user, #bid, ft2, #delayed, 1_500, 100_000, null);
  ignore auction.placeOrder(user2, #bid, ft1, #delayed, 1_500, 100_000, null);
  ignore auction.placeOrder(user2, #bid, ft2, #delayed, 1_500, 100_000, null);

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft1, 500_000_000);
  ignore auction.appendCredit(seller, ft2, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft1, #delayed, 200_000_000, 100_000, null);
  ignore auction.placeOrder(seller, #ask, ft2, #delayed, 200_000_000, 100_000, null);

  assert auction.getOrders(user, #bid, ?ft1).size() == 1;
  assert auction.getOrders(user, #bid, ?ft2).size() == 1;
  assert auction.getOrders(user2, #bid, ?ft1).size() == 1;
  assert auction.getOrders(user2, #bid, ?ft2).size() == 1;

  auction.processAsset(ft1);
  auction.processAsset(ft2);

  assert auction.getOrders(user, #bid, ?ft1).size() == 0;
  assert auction.getOrders(user, #bid, ?ft2).size() == 0;
  assert auction.getOrders(user2, #bid, ?ft1).size() == 0;
  assert auction.getOrders(user2, #bid, ?ft2).size() == 0;
};

do {
  Prim.debugPrint("should fulfil bids with the same price in order of insertion...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 2_000, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, 0, 500_000_000);
  ignore auction.placeOrder(user2, #bid, ft, #delayed, 999, 100_000, null);
  assert auction.getOrders(user2, #bid, ?ft).size() == 1;

  let user3 = Principal.fromText("3ekl2-xv73q-5v4oc-u3edq-dykz6-ps2k6-jxjiu-34myc-zc6rg-ucex3-4qe");
  ignore auction.appendCredit(user3, 0, 500_000_000);
  ignore auction.placeOrder(user3, #bid, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(user3, #bid, ?ft).size() == 1;

  auction.processAsset(ft);
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
  assert auction.getOrders(user2, #bid, ?ft).size() == 0;

  assert auction.getOrders(user3, #bid, ?ft).size() == 1;
  assert auction.getCredit(user3, ft).available == 1;
};

do {
  Prim.debugPrint("should fulfil lowest bid partially...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 3_500, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft, #delayed, 1_500, 200_000, null);
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  let user2 = Principal.fromText("tbsil-wffo6-dnxyb-b27v7-c5ghk-jsiqs-gsok7-bmtyu-w7u3b-el75k-iae");
  ignore auction.appendCredit(user2, 0, 500_000_000);
  ignore auction.placeOrder(user2, #bid, ft, #delayed, 1_500, 150_000, null);
  assert auction.getOrders(user2, #bid, ?ft).size() == 1;

  let user3 = Principal.fromText("3ekl2-xv73q-5v4oc-u3edq-dykz6-ps2k6-jxjiu-34myc-zc6rg-ucex3-4qe");
  ignore auction.appendCredit(user3, 0, 500_000_000);
  ignore auction.placeOrder(user3, #bid, ft, #delayed, 1_500, 100_000, null);
  assert auction.getOrders(user3, #bid, ?ft).size() == 1;

  // should be ignored (no supply)
  let user4 = Principal.fromText("4qjkc-5jhyl-gsuxu-hlkcq-p66js-epkn3-rlztj-f2exy-dgjxx-7zud4-tqe");
  ignore auction.appendCredit(user4, 0, 500_000_000);
  ignore auction.placeOrder(user4, #bid, ft, #delayed, 1_500, 50_000, null);
  assert auction.getOrders(user4, #bid, ?ft).size() == 1;

  auction.processAsset(ft);

  // check that price was 100 (lowest partially fulfilled bid). Queried deposit grew for high bidders
  assert auction.getCredit(user, ft).available == 1_500;
  assert auction.getCredit(user, 0).available == 350_000_000;
  assert auction.getCredit(user2, ft).available == 1_500;
  assert auction.getCredit(user2, 0).available == 350_000_000;
  // user whose bid was fulfilled partially
  assert auction.getCredit(user3, ft).available == 500;
  assert auction.getCredit(user3, 0).available == 350_000_000; // 100m is locked in the bid, 50m were charged
  // check bid. Volume should be lowered by 500
  let bids = auction.getOrders(user3, #bid, ?ft);
  assert bids.size() == 1;
  assert bids[0].1.price == 100_000;
  assert bids[0].1.volume == 1_000;
  // check that partial bid recorded in history
  let ?historyItem = auction.getTransactionHistory(user3, [ft], #desc).next() else Prim.trap("");
  assert historyItem.2 == #bid;
  assert historyItem.3 == ft;
  assert historyItem.4 == 500;
  assert historyItem.5 == 100_000;
};

do {
  Prim.debugPrint("should carry partially fulfilled bid over to the next session...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft, #delayed, 2_000, 100_000, null);
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;

  auction.processAsset(ft);

  // bid is still there
  assert auction.getOrders(user, #bid, ?ft).size() == 1;
  assert auction.getCredit(user, 0).available == 300_000_000;
  assert auction.getCredit(user, ft).available == 1_000; // was partially fulfilled

  // add another ask
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;

  auction.processAsset(ft);

  // bid should be fully fulfilled now
  assert auction.getOrders(user, #bid, ?ft).size() == 0;
  assert auction.getCredit(user, 0).available == 300_000_000;
  assert auction.getCredit(user, ft).available == 2_000;
};

do {
  Prim.debugPrint("should fulfil bids by priority and preserve priority between bids through sessions...");
  let (auction, _) = init(0, 3, 5);
  let ft = createFt(auction);
  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);

  let mediumBidder = Principal.fromText("skg6a-h7fc6-ffjkm-n3hhw-uagd3-upkxs-x5zls-gjx52-tqv7s-5hi7j-nae");
  ignore auction.appendCredit(mediumBidder, 0, 500_000_000);
  ignore auction.placeOrder(mediumBidder, #bid, ft, #delayed, 1_500, 20_000, null);
  assert auction.getOrders(mediumBidder, #bid, ?ft).size() == 1;
  let highBidder = Principal.fromText("7ddlt-3caok-vrxwe-wmyzk-vvfh6-squ7w-o5daa-7k2nu-jiewx-6y3mo-7qe");
  ignore auction.appendCredit(highBidder, 0, 500_000_000);
  ignore auction.placeOrder(highBidder, #bid, ft, #delayed, 1_500, 50_000, null);
  assert auction.getOrders(highBidder, #bid, ?ft).size() == 1;
  let lowBidder = Principal.fromText("pcrzk-kgmfw-7gaj5-ev6i3-2kpmo-mafjf-extsq-csmk6-cabdq-xjgvw-nae");
  ignore auction.appendCredit(lowBidder, 0, 500_000_000);
  ignore auction.placeOrder(lowBidder, #bid, ft, #delayed, 1_500, 5_000, null);
  assert auction.getOrders(lowBidder, #bid, ?ft).size() == 1;

  // allow one additional bid next session
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_500, 1_000, null);
  auction.processAsset(ft);
  assert auction.getOrders(highBidder, #bid, ?ft).size() == 0;
  assert auction.getOrders(mediumBidder, #bid, ?ft).size() == 1;
  assert auction.getOrders(lowBidder, #bid, ?ft).size() == 1;

  // allow one additional bid next session
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_500, 1_000, null);
  auction.processAsset(ft);
  assert auction.getOrders(mediumBidder, #bid, ?ft).size() == 0;
  assert auction.getOrders(lowBidder, #bid, ?ft).size() == 1;

  let newBidder = Principal.fromText("w4lvw-dxncd-7klkg-go27e-gqfza-4vufd-k66s4-dqi2e-nen6j-3ro2z-7qe");
  ignore auction.appendCredit(newBidder, 0, 500_000_000);
  ignore auction.placeOrder(newBidder, #bid, ft, #delayed, 1_500, 20_000, null);
  assert auction.getOrders(newBidder, #bid, ?ft).size() == 1;

  // allow one additional bid next session
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_500, 1_000, null);
  auction.processAsset(ft);
  // new bidder joined later, but should be fulfilled since priority greater than priority of low bid
  assert auction.getOrders(newBidder, #bid, ?ft).size() == 0;
  assert auction.getOrders(lowBidder, #bid, ?ft).size() == 1;

  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_500, 1_000, null);
  auction.processAsset(ft);
  // finally low bid will be fulfilled
  assert auction.getOrders(lowBidder, #bid, ?ft).size() == 0;
};

do {
  Prim.debugPrint("should be able to place another bid for next auction session...");
  let (auction, user) = init(0, 3, 5);
  let ft = createFt(auction);
  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  auction.processAsset(ft);

  assert auction.getOrders(seller, #ask, ?ft).size() == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 0;

  ignore auction.placeOrder(seller, #ask, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;
  ignore auction.placeOrder(user, #bid, ft, #delayed, 1_000, 100_000, null);
  assert auction.getOrders(user, #bid, ?ft).size() == 1;

  auction.processAsset(ft);

  assert auction.getOrders(seller, #ask, ?ft).size() == 0;
  assert auction.getOrders(user, #bid, ?ft).size() == 0;

  assert auction.getCredit(user, ft).available == 2_000;
};
