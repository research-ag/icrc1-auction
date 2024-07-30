import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Prim "mo:prim";

import { matchOrders } "mo:auction";

import AssetsRepo "./assets_repo";
import CreditsRepo "./credits_repo";
import OrdersRepo "./orders_repo";
import UsersRepo "./users_repo";
import T "./types";

module {

  public func processAuction(
    assetsRepo : AssetsRepo.AssetsRepo,
    creditsRepo : CreditsRepo.CreditsRepo,
    usersRepo : UsersRepo.UsersRepo,
    assetId : T.AssetId,
    sessionsCounter : Nat,
    trustedAssetId : T.AssetId,
    performanceCounter : Nat32 -> Nat64,
  ) {
    let startInstructions = performanceCounter(0);
    let assetInfo = assetsRepo.getAsset(assetId);
    let mapOrders = func(orders : List.List<(T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> = orders
    |> List.toIter<(T.OrderId, T.Order)>(_)
    |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

    let (_, _, dealVolume, price) = matchOrders(mapOrders(assetInfo.asks.queue), mapOrders(assetInfo.bids.queue));
    if (dealVolume == 0) {
      assetsRepo.pushToHistory(Prim.time(), sessionsCounter, assetId, 0, 0.0);
      return;
    };

    // process fulfilled asks
    var dealVolumeLeft = dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = assetsRepo.peekOrder(assetInfo, #ask) else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update ask in user info and calculate real ask volume
      let volume = if (dealVolumeLeft < order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        ignore usersRepo.popOrder(userInfo, #ask, orderId);
        assetsRepo.popOrder(assetInfo, #ask, orderId);
        order.volume;
      };
      dealVolumeLeft -= volume;
      // remove price from deposit
      let ?sourceAcc = creditsRepo.getAccount(userInfo, assetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit
      let (s1, _) = creditsRepo.unlockCredit(sourceAcc, volume);
      let (s2, _) = creditsRepo.deductCredit(sourceAcc, volume);
      assert s1 and s2;

      // credit user with trusted tokens
      let acc = creditsRepo.getOrCreate(userInfo, trustedAssetId);
      ignore creditsRepo.appendCredit(acc, OrdersRepo.getTotalPrice(volume, price));
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
    };

    // process fulfilled bids
    dealVolumeLeft := dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = assetsRepo.peekOrder(assetInfo, #bid) else Prim.trap("Can never happen: list shorter than before");
      let userInfo = order.userInfoRef;
      // update bid in user info and calculate real bid volume
      let volume = if (dealVolumeLeft < order.volume) {
        order.volume -= dealVolumeLeft;
        dealVolumeLeft;
      } else {
        ignore usersRepo.popOrder(userInfo, #bid, orderId);
        assetsRepo.popOrder(assetInfo, #bid, orderId);
        order.volume;
      };
      dealVolumeLeft -= volume;
      let ?trustedAcc = creditsRepo.getAccount(userInfo, trustedAssetId) else Prim.trap("Can never happen");
      // remove price from deposit and unlock locked deposit (note that it uses bid price)
      let (s1, _) = creditsRepo.unlockCredit(trustedAcc, OrdersRepo.getTotalPrice(volume, order.price));
      let (s2, _) = creditsRepo.deductCredit(trustedAcc, OrdersRepo.getTotalPrice(volume, price));
      assert s1 and s2;
      // credit user with tokens
      let acc = creditsRepo.getOrCreate(userInfo, assetId);
      ignore creditsRepo.appendCredit(acc, volume);
      // append to history
      userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
    };

    assetInfo.lastRate := price;
    // append to asset history
    assetsRepo.pushToHistory(Prim.time(), sessionsCounter, assetId, dealVolume, price);
    assetInfo.lastProcessingInstructions := Nat64.toNat(performanceCounter(0) - startInstructions);
  };

};
