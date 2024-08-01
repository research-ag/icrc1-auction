import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Prim "mo:prim";

import { matchOrders } "mo:auction";

import Assets "./assets";
import Credits "./credits";
import Orders "./orders";
import Users "./users";
import T "./types";

module {

  public func processAuction(
    assets : Assets.Assets,
    credits : Credits.Credits,
    users : Users.Users,
    assetId : T.AssetId,
    sessionsCounter : Nat,
    trustedAssetId : T.AssetId,
  ) : (volume : Nat, price : Float) {
    let assetInfo = assets.getAsset(assetId);
    let mapOrders = func(orders : List.List<(T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> = orders
    |> List.toIter<(T.OrderId, T.Order)>(_)
    |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

    let (_, _, dealVolume, price) = matchOrders(mapOrders(assetInfo.asks.queue), mapOrders(assetInfo.bids.queue));
    if (dealVolume == 0) {
      return (0, 0.0);
    };

    // process fulfilled asks
    var dealVolumeLeft = dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = assets.peekOrder(assetInfo, #ask) else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update ask in user info and calculate real ask volume
      let volume = if (dealVolumeLeft < order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        ignore users.deleteOrder(userInfo, #ask, orderId);
        assets.deleteOrder(assetInfo, #ask, orderId);
        order.volume;
      };
      dealVolumeLeft -= volume;
      // remove price from deposit
      let ?sourceAcc = credits.getAccount(userInfo, assetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit
      let (s1, _) = credits.unlockCredit(sourceAcc, volume);
      let (s2, _) = credits.deductCredit(sourceAcc, volume);
      assert s1 and s2;

      // credit user with trusted tokens
      let acc = credits.getOrCreate(userInfo, trustedAssetId);
      ignore credits.appendCredit(acc, Orders.getTotalPrice(volume, price));
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
    };

    // process fulfilled bids
    dealVolumeLeft := dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = assets.peekOrder(assetInfo, #bid) else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update bid in user info and calculate real bid volume
      let volume = if (dealVolumeLeft < order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        ignore users.deleteOrder(userInfo, #bid, orderId);
        assets.deleteOrder(assetInfo, #bid, orderId);
        order.volume;
      };
      dealVolumeLeft -= volume;
      let ?trustedAcc = credits.getAccount(userInfo, trustedAssetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit (note that it uses bid price)
      let (s1, _) = credits.unlockCredit(trustedAcc, Orders.getTotalPrice(volume, order.price));
      let (s2, _) = credits.deductCredit(trustedAcc, Orders.getTotalPrice(volume, price));
      assert s1 and s2;
      // credit user with tokens
      let acc = credits.getOrCreate(userInfo, assetId);
      ignore credits.appendCredit(acc, volume);
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
    };
    (dealVolume, price);
  };

};
