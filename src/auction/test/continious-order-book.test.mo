import Prim "mo:prim";
import Principal "mo:base/Principal";

import U "../../utils";
import { init; createFt } "./test.util";

// do {
//   Prim.debugPrint("immediate orders should execute immediately...");
//   let (auction, buyer) = init(0, 3, 5);
//   let ft = createFt(auction);
//   ignore auction.appendCredit(buyer, 0, 500_000_000);
//   let (_, res0) = U.requireOk(auction.placeOrder(buyer, #bid, ft, #immediate, 2_000, 15_000, null));
//   switch (res0) {
//     case (#placed) {};
//     case (#executed _) assert false;
//   };

//   let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");
//   ignore auction.appendCredit(seller, ft, 500_000_000);
//   let (_, result) = U.requireOk(auction.placeOrder(seller, #ask, ft, #immediate, 2_000, 15_000, null));
//   switch (result) {
//     case (#placed) assert false;
//     case (#executed(price, volume)) {
//       assert price == 15_000;
//       assert volume == 2_000;
//     };
//   };
//   assert auction.getOrders(buyer, #bid, ?ft).size() == 0;
//   assert auction.getOrders(seller, #ask, ?ft).size() == 0;
// };

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
  Prim.debugPrint("immediate and delayed orders should preserve priority (1)...");
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