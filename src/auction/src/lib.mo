/// A module which implements auction functionality for various trading pairs against "trusted" fungible token
///
/// Copyright: 2023-2024 MR Research AG
/// Main author: Andy Gura
/// Contributors: Timo Hanke

import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Option "mo:base/Option";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import R "mo:base/Result";

import Vec "mo:vector";
import { matchOrders } "mo:auction";

import AssetsRepo "assets_repo";
import CreditsRepo "./credits_repo";
import OrdersRepo "./orders_repo";
import {
  sliceList;
  sliceListWithFilter;
} "./utils";
import T "./types";
import UsersRepo "users_repo";

module {

  public func defaultStableDataV1() : T.StableDataV1 = {
    counters = (0, 0);
    assets = Vec.new();
    users = #leaf;
    history = null;
    stats = {
      usersAmount = 0;
      accountsAmount = 0;
      assets = Vec.new();
    };
  };
  public type StableDataV1 = T.StableDataV1;

  public type AssetId = T.AssetId;
  public type OrderId = T.OrderId;
  public type CreditInfo = CreditsRepo.CreditInfo;
  public type SharedOrder = T.SharedOrder;
  public type UserInfo = T.UserInfo;

  public type CancellationAction = OrdersRepo.CancellationAction;
  public type PlaceOrderAction = OrdersRepo.PlaceOrderAction;

  public type CancelOrderError = OrdersRepo.InternalCancelOrderError or {
    #UnknownPrincipal;
  };
  public type PlaceOrderError = OrdersRepo.InternalPlaceOrderError or {
    #UnknownPrincipal;
  };
  public type ReplaceOrderError = CancelOrderError or PlaceOrderError;

  public class Auction(
    trustedAssetId : AssetId,
    settings : {
      minimumOrder : Nat;
      minAskVolume : (AssetId, T.AssetInfo) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    // a counter of conducted auction sessions
    public var sessionsCounter = 0;

    public let usersRepo = UsersRepo.UsersRepo();
    public let creditsRepo = CreditsRepo.CreditsRepo();
    public let assetsRepo = AssetsRepo.AssetsRepo();
    public let ordersRepo = OrdersRepo.OrdersRepo(
      assetsRepo,
      creditsRepo,
      trustedAssetId,
      settings.minimumOrder,
      settings.minAskVolume,
    );

    public func registerAssets(n : Nat) = assetsRepo.register(n);

    public func queryCredit(p : Principal, assetId : AssetId) : CreditInfo = usersRepo.get(p)
    |> Option.map<UserInfo, CreditInfo>(_, func(ui) = creditsRepo.info(ui, assetId))
    |> Option.get(_, { total = 0; locked = 0; available = 0 });

    public func queryCredits(p : Principal) : [(AssetId, CreditInfo)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) {
        let length = List.size(ui.credits);
        var list = ui.credits;
        Array.tabulate<(AssetId, CreditInfo)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?x) (x.0, creditsRepo.accountInfo(x.1));
            };
          },
        );
      };
    };

    private func queryOrders_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, T.Order>) : [(OrderId, T.SharedOrder)] = switch (usersRepo.get(p)) {
      case (null) [];
      case (?ui) {
        var list = f(ui);
        let length = List.size(list);
        Array.tabulate<(OrderId, T.SharedOrder)>(
          length,
          func(i) {
            let popped = List.pop(list);
            list := popped.1;
            switch (popped.0) {
              case null { loop { assert false } };
              case (?(orderId, order)) (orderId, { order with volume = order.volume });
            };
          },
        );
      };
    };

    private func queryOrder_(p : Principal, f : (ui : UserInfo) -> AssocList.AssocList<OrderId, T.Order>, orderId : OrderId) : ?T.SharedOrder {
      switch (usersRepo.get(p)) {
        case (null) null;
        case (?ui) {
          for ((oid, order) in List.toIter(f(ui))) {
            if (oid == orderId) {
              return ?{ order with volume = order.volume };
            };
          };
          null;
        };
      };
    };

    public func queryAssetAsks(p : Principal, assetId : AssetId) : [(OrderId, T.SharedOrder)] = queryOrders_(
      p,
      func(info) = info.currentAsks |> List.filter<(OrderId, T.Order)>(_, func(_, o) = o.assetId == assetId),
    );
    public func queryAssetBids(p : Principal, assetId : AssetId) : [(OrderId, T.SharedOrder)] = queryOrders_(
      p,
      func(info) = info.currentBids |> List.filter<(OrderId, T.Order)>(_, func(_, o) = o.assetId == assetId),
    );

    public func queryAsks(p : Principal) : [(OrderId, T.SharedOrder)] = queryOrders_(p, func(info) = info.currentAsks);
    public func queryBids(p : Principal) : [(OrderId, T.SharedOrder)] = queryOrders_(p, func(info) = info.currentBids);

    public func queryAsk(p : Principal, orderId : OrderId) : ?T.SharedOrder = queryOrder_(p, func(info) = info.currentAsks, orderId);
    public func queryBid(p : Principal, orderId : OrderId) : ?T.SharedOrder = queryOrder_(p, func(info) = info.currentBids, orderId);

    public func queryTransactionHistory(p : Principal, assetId : ?AssetId, limit : Nat, skip : Nat) : [T.TransactionHistoryItem] {
      let ?userInfo = usersRepo.get(p) else return [];
      switch (assetId) {
        case (?aid) sliceListWithFilter(userInfo.history, func(item : T.TransactionHistoryItem) : Bool = item.3 == aid, limit, skip);
        case (null) sliceList(userInfo.history, limit, skip);
      };
    };

    public func queryPriceHistory(assetId : ?AssetId, limit : Nat, skip : Nat) : [T.PriceHistoryItem] {
      switch (assetId) {
        case (?aid) sliceListWithFilter(assetsRepo.history, func(item : T.PriceHistoryItem) : Bool = item.2 == aid, limit, skip);
        case (null) sliceList(assetsRepo.history, limit, skip);
      };
    };

    public func appendCredit(p : Principal, assetId : AssetId, amount : Nat) : Nat {
      let userInfo = usersRepo.getOrCreate(p);
      let acc = creditsRepo.getOrCreate(userInfo, assetId);
      creditsRepo.appendCredit(acc, amount);
    };

    public func deductCredit(p : Principal, assetId : AssetId, amount : Nat) : R.Result<(Nat, rollback : () -> ()), { #NoCredit }> {
      let ?user = usersRepo.get(p) else return #err(#NoCredit);
      let ?creditAcc = creditsRepo.getAccount(user, assetId) else return #err(#NoCredit);
      switch (creditsRepo.deductCredit(creditAcc, amount)) {
        case (true, balance) #ok(balance, func() = ignore creditsRepo.appendCredit(creditAcc, amount));
        case (false, _) #err(#NoCredit);
      };
    };

    public func manageOrders(
      p : Principal,
      cancellations : ?OrdersRepo.CancellationAction,
      placements : [OrdersRepo.PlaceOrderAction],
    ) : R.Result<[OrderId], OrdersRepo.OrderManagementError or { #UnknownPrincipal }> {
      let ?userInfo = usersRepo.get(p) else return #err(#UnknownPrincipal);
      ordersRepo.manageOrders(p, userInfo, cancellations, placements);
    };

    public func placeAsk(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      switch (manageOrders(p, null, [#ask(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
        case (_) Prim.trap("Can never happen");
      };
    };

    public func replaceAsk(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (queryAsk(p, orderId)) {
        case (?ask) ask.assetId;
        case (null) return #err(#UnknownOrder);
      };
      switch (manageOrders(p, ? #orders([#ask(orderId)]), [#ask(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) switch (error) {
          case (#UnknownOrder) #err(#UnknownOrder);
        };
        case (#err(#placement({ error }))) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
      };
    };

    public func cancelAsk(p : Principal, orderId : OrderId) : R.Result<(), CancelOrderError> {
      switch (manageOrders(p, ? #orders([#ask(orderId)]), [])) {
        case (#ok _) #ok();
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement _)) Prim.trap("Can never happen");
        case (#err(#cancellation({ error }))) switch (error) {
          case (#UnknownOrder) #err(#UnknownOrder);
        };
      };
    };

    public func placeBid(p : Principal, assetId : AssetId, volume : Nat, price : Float) : R.Result<OrderId, PlaceOrderError> {
      switch (manageOrders(p, null, [#bid(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#placement { error })) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
        case (_) Prim.trap("Can never happen");
      };
    };

    public func replaceBid(p : Principal, orderId : OrderId, volume : Nat, price : Float) : R.Result<OrderId, ReplaceOrderError> {
      let assetId = switch (queryBid(p, orderId)) {
        case (?bid) bid.assetId;
        case (null) return #err(#UnknownOrder);
      };
      switch (manageOrders(p, ? #orders([#bid(orderId)]), [#bid(assetId, volume, price)])) {
        case (#ok orderIds) #ok(orderIds[0]);
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement({ error }))) switch (error) {
          case (#ConflictingOrder x) #err(#ConflictingOrder(x));
          case (#NoCredit) #err(#NoCredit);
          case (#TooLowOrder) #err(#TooLowOrder);
          case (#UnknownAsset) #err(#UnknownAsset);
        };
      };
    };

    public func cancelBid(p : Principal, orderId : OrderId) : R.Result<(), CancelOrderError> {
      switch (manageOrders(p, ? #orders([#bid(orderId)]), [])) {
        case (#ok _) #ok();
        case (#err(#UnknownPrincipal)) #err(#UnknownPrincipal);
        case (#err(#cancellation({ error }))) #err(error);
        case (#err(#placement _)) Prim.trap("Can never happen");
      };
    };

    // processes auction for given asset
    public func processAsset(assetId : AssetId) : () {
      if (assetId == trustedAssetId) return;
      let startInstructions = settings.performanceCounter(0);

      let assetInfo = Vec.get(assetsRepo.assets, assetId);
      let mapOrders = func(orders : List.List<(OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> = orders
      |> List.toIter<(OrderId, T.Order)>(_)
      |> Iter.map<(OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

      let (nAsks, nBids, dealVolume, price) = matchOrders(mapOrders(assetInfo.asks), mapOrders(assetInfo.bids));
      if (nAsks == 0 or nBids == 0) {
        assetsRepo.history := List.push((Prim.time(), sessionsCounter, assetId, 0, 0.0), assetsRepo.history);
        return;
      };

      // process fulfilled asks
      var i = 0;
      var dealVolumeLeft = dealVolume;
      var asksTail = assetInfo.asks;
      label b while (i < nAsks) {
        let ?((orderId, order), next) = asksTail else Prim.trap("Can never happen: list shorter than before");
        let userInfo = order.userInfoRef;
        // update ask in user info and calculate real ask volume
        let volume = if (i + 1 == nAsks and dealVolumeLeft != order.volume) {
          order.volume -= dealVolumeLeft;
          dealVolumeLeft;
        } else {
          AssocList.replace<OrderId, T.Order>(userInfo.currentAsks, orderId, Nat.equal, null) |> (userInfo.currentAsks := _.0);
          asksTail := next;
          assetInfo.asksAmount -= 1;
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
        assetInfo.totalAskVolume -= volume;
        // append to history
        userInfo.history := List.push((Prim.time(), sessionsCounter, #ask, assetId, volume, price), userInfo.history);
        i += 1;
      };
      assetInfo.asks := asksTail;

      // process fulfilled bids
      i := 0;
      dealVolumeLeft := dealVolume;
      var bidsTail = assetInfo.bids;
      label b while (i < nBids) {
        let ?((orderId, order), next) = bidsTail else Prim.trap("Can never happen: list shorter than before");
        let userInfo = order.userInfoRef;
        // update bid in user info and calculate real bid volume
        let volume = if (i + 1 == nBids and dealVolumeLeft != order.volume) {
          order.volume -= dealVolumeLeft;
          dealVolumeLeft;
        } else {
          AssocList.replace<OrderId, T.Order>(userInfo.currentBids, orderId, Nat.equal, null) |> (userInfo.currentBids := _.0);
          bidsTail := next;
          assetInfo.bidsAmount -= 1;
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
        assetInfo.totalBidVolume -= volume;
        // append to history
        userInfo.history := List.push((Prim.time(), sessionsCounter, #bid, assetId, volume, price), userInfo.history);
        i += 1;
      };
      assetInfo.bids := bidsTail;

      assetInfo.lastRate := price;
      // append to asset history
      assetsRepo.history := List.push((Prim.time(), sessionsCounter, assetId, dealVolume, price), assetsRepo.history);
      assetInfo.lastProcessingInstructions := Nat64.toNat(settings.performanceCounter(0) - startInstructions);
    };

    public func share() : T.StableDataV1 = {
      counters = (sessionsCounter, ordersRepo.ordersCounter);
      assets = Vec.map<T.AssetInfo, T.StableAssetInfo>(
        assetsRepo.assets,
        func(x) = {
          asks = x.asks;
          bids = x.bids;
          lastRate = x.lastRate;
        },
      );
      stats = {
        usersAmount = usersRepo.usersAmount;
        accountsAmount = creditsRepo.accountsAmount;
        assets = Vec.map<T.AssetInfo, { bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }>(
          assetsRepo.assets,
          func(x) = {
            bidsAmount = x.bidsAmount;
            totalBidVolume = x.totalBidVolume;
            asksAmount = x.asksAmount;
            totalAskVolume = x.totalAskVolume;
            lastProcessingInstructions = x.lastProcessingInstructions;
          },
        );
      };
      users = usersRepo.users.share();
      history = assetsRepo.history;
    };

    public func unshare(data : T.StableDataV1) {
      sessionsCounter := data.counters.0;
      ordersRepo.ordersCounter := data.counters.1;
      assetsRepo.assets := Vec.new();
      for (i in Vec.keys(data.assets)) {
        let x = Vec.get(data.assets, i);
        let xs = Vec.get(data.stats.assets, i);
        Vec.add(
          assetsRepo.assets,
          {
            var asks = x.asks;
            var bids = x.bids;
            var lastRate = x.lastRate;
            var bidsAmount = xs.bidsAmount;
            var totalBidVolume = xs.totalBidVolume;
            var asksAmount = xs.asksAmount;
            var totalAskVolume = xs.totalAskVolume;
            var lastProcessingInstructions = xs.lastProcessingInstructions;
          },
        );
      };
      creditsRepo.accountsAmount := data.stats.accountsAmount;
      usersRepo.usersAmount := data.stats.usersAmount;
      usersRepo.users.unshare(data.users);
      assetsRepo.history := data.history;
    };

  };

};
