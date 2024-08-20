import Prim "mo:prim";
import Principal "mo:base/Principal";

import { init; createFt } "./test.util";

do {
  Prim.debugPrint("rounding test: small asks vs big bid...");
  let (auction, user) = init(0, 0, 0);
  let ft = createFt(auction);

  // user places big bid, which will be fulfilled with many smaller asks
  ignore auction.appendCredit(user, 0, 500_000_000);

  let seller1 = Principal.fromText("dkkzx-rn4st-jpxtx-c2q6z-wy2k7-uyffr-ks7hq-azcmt-zjwxi-btxoi-mqe");
  ignore auction.appendCredit(seller1, ft, 1_000);
  let seller2 = Principal.fromText("v5ec2-tmkq6-4v4pj-3piks-4liht-fiayb-itoch-hqkzi-cx4y7-ilhh3-hae");
  ignore auction.appendCredit(seller2, ft, 1_000);
  let seller3 = Principal.fromText("6gpuk-wazec-cgn76-wwyg2-tacww-edf2b-pek6i-qpmi6-qqxts-lasj7-rae");
  ignore auction.appendCredit(seller3, ft, 1_000);
  let seller4 = Principal.fromText("qo2aj-uwwcl-gw2to-zzmko-mdptl-ogqy3-ondre-dmlra-tal7p-klf4v-uae");
  ignore auction.appendCredit(seller4, ft, 1_000);

  switch (auction.placeOrder(user, #bid, ft, 4_000, 1)) {
    case (#ok _) ();
    case (_) assert false;
  };

  switch (auction.placeOrder(seller1, #ask, ft, 1_000, 0.0125)) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.placeOrder(seller2, #ask, ft, 1_000, 0.0125)) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.placeOrder(seller3, #ask, ft, 1_000, 0.0125)) {
    case (#ok _) ();
    case (_) assert false;
  };
  switch (auction.placeOrder(seller4, #ask, ft, 1_000, 0.0125)) {
    case (#ok _) ();
    case (_) assert false;
  };

  auction.processAsset(ft);

  let ?priceHistoryItem = auction.getPriceHistory(?ft).next() else Prim.trap("");
  assert priceHistoryItem.3 == 4_000; // volume
  assert priceHistoryItem.4 == 0.0125;

  // rounding problem: bidder spends volume without rounding, 4_000 * 0.0125 = 50,
  // but selers get 12.5 each, so we need to make sure we won't round it up to 13, because in total we will issue 13 * 4 = 52

  assert auction.getCredit(user, 0).available == (500_000_000 : Nat - 50 : Nat);
  assert auction.getCredit(user, ft).available == 4_000;

  assert auction.getCredit(seller1, 0).available == 12;
  assert auction.getCredit(seller1, ft).available == 0;
  assert auction.getCredit(seller2, 0).available == 12;
  assert auction.getCredit(seller2, ft).available == 0;
  assert auction.getCredit(seller3, 0).available == 12;
  assert auction.getCredit(seller3, ft).available == 0;
  assert auction.getCredit(seller4, 0).available == 12;
  assert auction.getCredit(seller4, ft).available == 0;

  assert auction.credits.quoteSurplus == 2;

};
