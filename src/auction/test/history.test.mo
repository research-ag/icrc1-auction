import Iter "mo:base/Iter";
import Prim "mo:prim";
import Principal "mo:base/Principal";

import { init; createFt } "./test.util";

do {
  Prim.debugPrint("should return price history with descending order...");
  let (auction, user) = init(0);
  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");

  let ft1 = createFt(auction);
  ignore auction.appendCredit(seller, ft1, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft1, 1_000, 0);

  let ft2 = createFt(auction);
  ignore auction.appendCredit(seller, ft2, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft2, 1_000, 0);

  let ft3 = createFt(auction);

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft1, 1_000, 100_000);
  ignore auction.placeOrder(user, #bid, ft2, 1_000, 100_000);

  auction.processAsset(ft1);
  auction.processAsset(ft2);
  auction.processAsset(ft3);

  let history = Iter.toArray(auction.getPriceHistory(null));
  assert history.size() == 3;
  assert history[0].2 == ft3;
  assert history[0].3 == 0;
  assert history[0].4 == 0;
  assert history[1].2 == ft2;
  assert history[1].3 == 1_000;
  assert history[1].4 == 100_000;
  assert history[2].2 == ft1;
  assert history[2].3 == 1_000;
  assert history[2].4 == 100_000;
};

do {
  Prim.debugPrint("should return transaction history with descending order...");
  let (auction, user) = init(0);
  let seller = Principal.fromText("ocqy6-3dphi-xgf54-vkr2e-lk4oz-3exc6-446gr-5e72g-bsdfo-4nzrm-hqe");

  let ft1 = createFt(auction);
  ignore auction.appendCredit(seller, ft1, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft1, 1_000, 0);

  let ft2 = createFt(auction);
  ignore auction.appendCredit(seller, ft2, 500_000_000);
  ignore auction.placeOrder(seller, #ask, ft2, 1_000, 0);

  ignore auction.appendCredit(user, 0, 500_000_000);
  ignore auction.placeOrder(user, #bid, ft1, 1_000, 100_000);
  ignore auction.placeOrder(user, #bid, ft2, 1_000, 100_000);

  auction.processAsset(ft1);
  auction.processAsset(ft2);

  let history = Iter.toArray(auction.getTransactionHistory(user, null));
  assert history[0].3 == ft2;
  assert history[1].3 == ft1;
};
