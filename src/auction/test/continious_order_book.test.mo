import Iter "mo:base/Iter";
import Prim "mo:prim";
import Principal "mo:base/Principal";

import U "../../utils";
import { init; createFt } "./test.util";

do {
  Prim.debugPrint("immediate orders should execute immediately...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);
  let (_, res0) = U.requireOk(auction.placeOrder(buyer, #bid, ft, #immediate, 2_000, 15_000, null));
  switch (res0) {
    case (#placed) {};
    case (#executed _) assert false;
  };

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);

  assert auction.getCredit(buyer, ft) == {
    available = 0;
    locked = 0;
    total = 0;
  };
  assert auction.getCredit(seller, ft) == {
    available = 500_000_000;
    locked = 0;
    total = 500_000_000;
  };

  let brev = auction.getAccountRevision(buyer);
  let srev = auction.getAccountRevision(buyer);

  let (_, result) = U.requireOk(auction.placeOrder(seller, #ask, ft, #immediate, 2_000, 15_000, null));
  switch (result) {
    case (#placed) assert false;
    case (#executed res) {
      let (price, volume) = res[0];
      assert price == 15_000;
      assert volume == 2_000;
    };
  };
  assert auction.getOrders(buyer, #bid, ?ft).size() == 0;
  assert auction.getOrders(seller, #ask, ?ft).size() == 0;

  // check that accounts were updated
  assert auction.getCredit(buyer, ft) == {
    available = 2_000;
    locked = 0;
    total = 2_000;
  };
  assert auction.getCredit(seller, ft) == {
    available = 499_998_000;
    locked = 0;
    total = 499_998_000;
  };
  assert auction.getAccountRevision(buyer) > brev;
  assert auction.getAccountRevision(buyer) > srev;

  // check history
  let history = Iter.toArray(auction.getImmediatePriceHistory([ft], #desc));
  assert history.size() == 1;
  assert history[0].2 == ft;
  assert history[0].3 == 2_000;
  assert history[0].4 == 15_000;
};

do {
  Prim.debugPrint("immediate orders execution should fulfil as many orders as possible...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);

  let seller0 = Principal.fromText("sqez4-4bl6d-ymcv2-npdsk-p3xpk-zlwzb-isfiz-estoh-ioiez-rogoj-yqe");
  ignore auction.appendCredit(seller0, ft, 500_000_000);
  let seller1 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(seller1, ft, 500_000_000);

  let (_, result0) = U.requireOk(auction.placeOrder(seller0, #ask, ft, #immediate, 2_000, 15_000, null));
  switch (result0) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  let (_, result1) = U.requireOk(auction.placeOrder(seller1, #ask, ft, #immediate, 2_000, 16_000, null));
  switch (result1) {
    case (#placed) {};
    case (#executed _) assert false;
  };

  assert auction.getOrders(seller0, #ask, ?ft).size() == 1;
  assert auction.getOrders(seller1, #ask, ?ft).size() == 1;

  let (oid, result2) = U.requireOk(auction.placeOrder(buyer, #bid, ft, #immediate, 5_000, 18_000, null));
  switch (result2) {
    case (#placed) assert false;
    case (#executed res) {
      // 2_000 volume from seller0
      assert res[0].0 == 15_000;
      assert res[0].1 == 2_000;
      // 2_000 volume from seller1
      assert res[1].0 == 16_000;
      assert res[1].1 == 2_000;
    };
  };
  let ?order = auction.getOrder(buyer, #bid, oid) else Prim.trap("order not found");
  assert order.volume == 1_000;
  assert order.price == 18_000;

  assert auction.getOrders(seller0, #ask, ?ft).size() == 0;
  assert auction.getOrders(seller1, #ask, ?ft).size() == 0;
};

do {
  Prim.debugPrint("delayed orders should not be fulfilled by immediate order...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);
  ignore U.requireOk(auction.placeOrder(buyer, #bid, ft, #delayed, 2_000, 15_000, null));

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  let (_, result) = U.requireOk(auction.placeOrder(seller, #ask, ft, #immediate, 2_000, 15_000, null));
  switch (result) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  assert auction.getOrders(buyer, #bid, ?ft).size() == 1;
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;
};

do {
  Prim.debugPrint("auction run should executed immediate orders and delayed ones...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);
  ignore U.requireOk(auction.placeOrder(buyer, #bid, ft, #delayed, 2_000, 15_000, null));

  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
  ignore auction.appendCredit(seller, ft, 500_000_000);
  ignore U.requireOk(auction.placeOrder(seller, #ask, ft, #immediate, 2_000, 15_000, null));

  assert auction.getOrders(buyer, #bid, ?ft).size() == 1;
  assert auction.getOrders(seller, #ask, ?ft).size() == 1;
  auction.processAsset(ft);
  assert auction.getOrders(buyer, #bid, ?ft).size() == 0;
  assert auction.getOrders(seller, #ask, ?ft).size() == 0;
};

do {
  Prim.debugPrint("immediate and delayed orders should preserve priority (1)...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);
  ignore U.requireOk(auction.placeOrder(buyer, #bid, ft, #delayed, 2_000, 15_000, null));

  let seller0 = Principal.fromText("sqez4-4bl6d-ymcv2-npdsk-p3xpk-zlwzb-isfiz-estoh-ioiez-rogoj-yqe");
  ignore auction.appendCredit(seller0, ft, 500_000_000);
  ignore U.requireOk(auction.placeOrder(seller0, #ask, ft, #immediate, 1_500, 14_000, null));

  let seller1 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(seller0, ft, 500_000_000);
  ignore U.requireOk(auction.placeOrder(seller0, #ask, ft, #delayed, 1_500, 13_000, null));

  auction.processAsset(ft);
  // sold with price 13_000 by seller1 (delayed ask)
  assert auction.getOrders(seller0, #ask, ?ft).size() == 1;
  assert auction.getOrders(seller1, #ask, ?ft).size() == 0;
};

do {
  Prim.debugPrint("immediate and delayed orders should preserve priority (2)...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);
  ignore U.requireOk(auction.placeOrder(buyer, #bid, ft, #delayed, 2_000, 15_000, null));

  let seller0 = Principal.fromText("sqez4-4bl6d-ymcv2-npdsk-p3xpk-zlwzb-isfiz-estoh-ioiez-rogoj-yqe");
  ignore auction.appendCredit(seller0, ft, 500_000_000);
  ignore U.requireOk(auction.placeOrder(seller0, #ask, ft, #delayed, 1_500, 14_000, null));

  let seller1 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(seller0, ft, 500_000_000);
  ignore U.requireOk(auction.placeOrder(seller0, #ask, ft, #immediate, 1_500, 13_000, null));

  auction.processAsset(ft);
  // sold with price 13_000 by seller1 (immediate ask)
  assert auction.getOrders(seller0, #ask, ?ft).size() == 1;
  assert auction.getOrders(seller1, #ask, ?ft).size() == 0;
};

do {
  Prim.debugPrint("immediate orders should execute against multiple opposite orders with different prices (bid case)...");
  let (auction, buyer) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(buyer, 0, 500_000_000);

  let seller1 = Principal.fromText("sqez4-4bl6d-ymcv2-npdsk-p3xpk-zlwzb-isfiz-estoh-ioiez-rogoj-yqe");
  ignore auction.appendCredit(seller1, ft, 500_000_000);
  let seller2 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(seller2, ft, 500_000_000);

  let (_, result1) = U.requireOk(auction.placeOrder(seller1, #ask, ft, #immediate, 500, 15_000, null));
  switch (result1) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  let (_, result2) = U.requireOk(auction.placeOrder(seller2, #ask, ft, #immediate, 500, 18_000, null));
  switch (result2) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  assert auction.getOrders(seller1, #ask, ?ft).size() == 1;
  assert auction.getOrders(seller2, #ask, ?ft).size() == 1;

  let (_, result3) = U.requireOk(auction.placeOrder(buyer, #bid, ft, #immediate, 1000, 20_000, null));
  switch (result3) {
    case (#placed) assert false;
    case (#executed res) {
      // 500 volume from seller1
      assert res[0].0 == 15_000;
      assert res[0].1 == 500;
      // 500 volume from seller2
      assert res[1].0 == 18_000;
      assert res[1].1 == 500;
    };
  };

  assert auction.getOrders(seller1, #ask, ?ft).size() == 0;
  assert auction.getOrders(seller2, #ask, ?ft).size() == 0;

  assert auction.getCredit(buyer, ft) == {
    available = 1000;
    locked = 0;
    total = 1000;
  };

  assert auction.getCredit(seller1, 0) == {
    available = 7_500_000;
    locked = 0;
    total = 7_500_000;
  };
  assert auction.getCredit(seller2, 0) == {
    available = 9_000_000;
    locked = 0;
    total = 9_000_000;
  };

  let history = Iter.toArray(auction.getImmediatePriceHistory([ft], #desc));
  assert history.size() == 2;
  assert history[0].2 == ft;
  assert history[0].3 == 500;
  assert history[0].4 == 18_000;
  assert history[1].2 == ft;
  assert history[1].3 == 500;
  assert history[1].4 == 15_000;
};

do {
  Prim.debugPrint("immediate orders should execute against multiple opposite orders with different prices (ask case)...");
  let (auction, seller) = init(0, 3, 5);
  let ft = createFt(auction);
  ignore auction.appendCredit(seller, ft, 500_000_000);
  let buyer1 = Principal.fromText("sqez4-4bl6d-ymcv2-npdsk-p3xpk-zlwzb-isfiz-estoh-ioiez-rogoj-yqe");
  ignore auction.appendCredit(buyer1, 0, 500_000_000);
  let buyer2 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(buyer2, 0, 500_000_000);

  let (_, result1) = U.requireOk(auction.placeOrder(buyer1, #bid, ft, #immediate, 500, 15_000, null));
  switch (result1) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  let (_, result2) = U.requireOk(auction.placeOrder(buyer2, #bid, ft, #immediate, 500, 18_000, null));
  switch (result2) {
    case (#placed) {};
    case (#executed _) assert false;
  };
  assert auction.getOrders(buyer1, #bid, ?ft).size() == 1;
  assert auction.getOrders(buyer2, #bid, ?ft).size() == 1;

  let (_, result3) = U.requireOk(auction.placeOrder(seller, #ask, ft, #immediate, 1000, 14_000, null));
  switch (result3) {
    case (#placed) assert false;
    case (#executed res) {
      // 500 volume from buyer2
      assert res[0].0 == 18_000;
      assert res[0].1 == 500;
      // 500 volume from buyer1
      assert res[1].0 == 15_000;
      assert res[1].1 == 500;
    };
  };

  assert auction.getOrders(buyer1, #bid, ?ft).size() == 0;
  assert auction.getOrders(buyer2, #bid, ?ft).size() == 0;

  assert auction.getCredit(seller, 0) == {
    available = 16_500_000;
    locked = 0;
    total = 16_500_000;
  };

  assert auction.getCredit(buyer1, ft) == {
    available = 500;
    locked = 0;
    total = 500;
  };
  assert auction.getCredit(buyer2, ft) == {
    available = 500;
    locked = 0;
    total = 500;
  };

  let history = Iter.toArray(auction.getImmediatePriceHistory([ft], #desc));
  assert history.size() == 2;
  assert history[0].2 == ft;
  assert history[0].3 == 500;
  assert history[0].4 == 15_000;
  assert history[1].2 == ft;
  assert history[1].3 == 500;
  assert history[1].4 == 18_000;
};
