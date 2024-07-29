import AssocList "mo:base/AssocList";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Prim "mo:prim";

import { matchOrders } "mo:auction";
import Vec "mo:vector";

import AssetsRepo "./assets_repo";
import CreditsRepo "./credits_repo";
import OrdersRepo "./orders_repo";
import T "./types";

module {

  public func processAuction(
    assetsRepo : AssetsRepo.AssetsRepo,
    creditsRepo : CreditsRepo.CreditsRepo,
    assetId : T.AssetId,
    sessionsCounter : Nat,
    trustedAssetId : T.AssetId,
    performanceCounter : Nat32 -> Nat64,
  ) {
    let startInstructions = performanceCounter(0);
    let assetInfo = Vec.get(assetsRepo.assets, assetId);
    let mapOrders = func(orders : List.List<(T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> = orders
    |> List.toIter<(T.OrderId, T.Order)>(_)
    |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

    let (nAsks, nBids, dealVolume, price) = matchOrders(mapOrders(assetInfo.asks.queue), mapOrders(assetInfo.bids.queue));
    if (nAsks == 0 or nBids == 0) {
      assetsRepo.history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), assetsRepo.history);
      return;
    };

    // process fulfilled asks
    var i = 0;
    var dealVolumeLeft = dealVolume;
    var asksTail = assetInfo.asks.queue;
    label b while (i < nAsks) {
      let ?((orderId, order), next) = asksTail else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update ask in user info and calculate real ask volume
      let volume = if (i + 1 == nAsks and dealVolumeLeft != order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        AssocList.replace<T.OrderId, T.Order>(userInfo.asks.map, orderId, Nat.equal, null) |> (userInfo.asks.map := _.0);
        asksTail := next;
        assetInfo.asks.amount -= 1;
        dealVolumeLeft -= order.volume;
        order.volume;
      };
      // remove price from deposit
      let ?sourceAcc = creditsRepo.getAccount(userInfo, assetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit
      let (s1, _) = creditsRepo.unlockCredit(sourceAcc, volume);
      let (s2, _) = creditsRepo.deductCredit(sourceAcc, volume);
      assert s1;
      assert s2;

      // credit user with trusted tokens
      let acc = creditsRepo.getOrCreate(userInfo, trustedAssetId);
      ignore creditsRepo.appendCredit(acc, OrdersRepo.getTotalPrice(volume, price));
      // update stats
      assetInfo.asks.totalVolume -= volume;
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
      i += 1;
    };
    assetInfo.asks.queue := asksTail;

    // process fulfilled bids
    i := 0;
    dealVolumeLeft := dealVolume;
    var bidsTail = assetInfo.bids.queue;
    label b while (i < nBids) {
      let ?((orderId, order), next) = bidsTail else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update bid in user info and calculate real bid volume
      let volume = if (i + 1 == nBids and dealVolumeLeft != order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        AssocList.replace<T.OrderId, T.Order>(userInfo.bids.map, orderId, Nat.equal, null) |> (userInfo.bids.map := _.0);
        bidsTail := next;
        assetInfo.bids.amount -= 1;
        dealVolumeLeft -= order.volume;
        order.volume;
      };
      let ?trustedAcc = creditsRepo.getAccount(userInfo, trustedAssetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit (note that it uses bid price)
      let (s1, _) = creditsRepo.unlockCredit(trustedAcc, OrdersRepo.getTotalPrice(volume, order.price));
      let (s2, _) = creditsRepo.deductCredit(trustedAcc, OrdersRepo.getTotalPrice(volume, price));
      assert s1;
      assert s2;
      // credit user with tokens
      let acc = creditsRepo.getOrCreate(userInfo, assetId);
      ignore creditsRepo.appendCredit(acc, volume);
      // update stats
      assetInfo.bids.totalVolume -= volume;
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
      i += 1;
    };
    assetInfo.bids.queue := bidsTail;

    assetInfo.lastRate := price;
    // append to asset history
    assetsRepo.history := List.push((Prim.time(), sessionsCounter, assetId, dealVolume, price), assetsRepo.history);
    assetInfo.lastProcessingInstructions := Nat64.toNat(performanceCounter(0) - startInstructions);
  };

};
