import Array "mo:core/Array";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";
import R "mo:core/Result";
import VarArray "mo:core/VarArray";
import Prim "mo:prim";

import PriorityQueue "./models/priority_queue";

import Account "./account";
import Asset "./asset";
import AssetsStorage "./assets_storage";
import C "./constants";
import OrderServices "./order_services";
import Processor "./auction_processor";
import User "./user";
import UsersStorage "./users_storage";
import T "./types";

module {

  // instance of this class should be declared as transient. It does not contain any data that must be stored in stable data
  public class AuctionRuntime(
    auction : T.Auction,
    runtimeSettings_ : {
      minAskVolume : (T.AssetId, T.Asset) -> Int;
      performanceCounter : Nat32 -> Nat64;
    },
  ) {

    public let runtimeSettings = runtimeSettings_;

    // This field does not survive upgrades, since we (currently) send them straight away
    public var stagedPushNotifications : Queue.Queue<(user : Principal, notification : T.PushNotification)> = Queue.empty();

    public func stagePushNotification(user : Principal, notification : T.PushNotification) {
      stagedPushNotifications.pushBack((user, notification));
    };

    public let quoteVolumeStep : Nat = 10 ** auction.settings.volumeStepLog10;
    public let minQuoteVolume : Nat = auction.settings.minVolumeSteps * quoteVolumeStep;
    public let priceMaxDigits : Nat = auction.settings.priceMaxDigits;

    public let asks : OrderServices.OrdersService = OrderServices.OrdersService(
      auction.assets,
      auction.users,
      auction.quoteAssetId,
      minQuoteVolume,
      runtimeSettings.minAskVolume,
      #ask,
    );

    public let bids : OrderServices.OrdersService = OrderServices.OrdersService(
      auction.assets,
      auction.users,
      auction.quoteAssetId,
      minQuoteVolume,
      runtimeSettings.minAskVolume,
      #bid,
    );

    public var executeImmediateOrderBooks : ?((assetId : T.AssetId, advantageFor : { #ask; #bid }) -> [(price : Float, volume : Nat, fulfilledOrders : PureList.List<{ order : T.Order; baseVolume : Nat; quoteVolume : Nat; isPartial : Bool; kind : { #ask; #bid } }>)]) = ?(
      func(assetId : T.AssetId, advantageFor : { #ask; #bid }) : [(price : Float, volume : Nat, fulfilledOrders : PureList.List<Processor.FulfilledOrder>)] {
        if (assetId == auction.quoteAssetId) return [];
        let assetInfo = auction.assets.getAsset(assetId);
        let ret = List.empty<(Float, Nat, PureList.List<Processor.FulfilledOrder>)>();
        let asksExecution = asks.createOrderBookExecutionService(assetInfo, #immediate);
        let bidsExecution = bids.createOrderBookExecutionService(assetInfo, #immediate);
        label l while true {
          let (_, volume) = Processor.clearAuction(asksExecution, bidsExecution);
          if (volume == 0) {
            break l;
          };
          let ?(_, { price }) = switch (advantageFor) {
            case (#ask) bidsExecution.nextOrder();
            case (#bid) asksExecution.nextOrder();
          } else Prim.trap("Can never happen");
          let { quoteSurplus; fulfilledOrders } = Processor.processAuction(0, asksExecution, bidsExecution, price, volume);
          if (quoteSurplus > 0) {
            auction.users.quoteSurplus += quoteSurplus;
          };
          ret.add((price, volume, fulfilledOrders));
          let executionsCounter = assetInfo.immediateExecutionsCounter;
          assetInfo.immediateExecutionsCounter += 1;
          auction.assets.pushToHistory(#immediate, (Prim.time(), executionsCounter, assetId, volume, price));
          assetInfo.lastImmediateRate := price;
        };
        ret.toArray();
      }
    );

    public func getBaseVolumeStep(price : Float) : Nat {
      let p = price / Int.toFloat(10 ** auction.settings.volumeStepLog10);
      if (p >= 1) return 1;
      let zf = - Float.log(p) / 2.302_585_092_994_045;
      Int.abs(10 ** Float.toInt(zf));
    };

    public func roundPriceDigits(price : Float) : ?Float {
      if (price >= 1) {
        let e1 = Float.log(price) / 2.302_585_092_994_045;
        let e = Float.trunc(e1);
        let m = 10 ** (e + 1 - Int.toFloat(priceMaxDigits));
        let n = price / m; // normalized
        let r = Float.nearest(n); // rounded
        if (Float.abs(n - r) < 1e-10) {
          ?(r * m);
        } else {
          null;
        };
      } else {
        let e1 = Float.log(price) / 2.302_585_092_994_047;
        let e = Float.trunc(e1);
        let m = 10 ** (Int.toFloat(priceMaxDigits) - e);
        let n = price * m; // normalized
        let r = Float.nearest(n); // rounded
        if (Float.abs(n - r) < 1e-10) {
          ?(r / m);
        } else {
          null;
        };
      };
    };

    public func manageOrders(
      p : Principal,
      userIndex : Nat,
      cancellations : ?T.CancellationAction,
      placements : [T.PlaceOrderAction],
      expectedAccountRevision : ?Nat,
    ) : R.Result<([T.CancellationResult], [T.PlaceOrderResult]), T.OrderManagementError> {
      let user = auction.users.atIndex(userIndex);
      switch (expectedAccountRevision) {
        case (?rev) {
          if (rev != user.accountRevision) {
            return #err(#AccountRevisionMismatch);
          };
        };
        case (null) {};
      };

      // temporary list of new balances for all affected user credit accounts
      let newBalances : Map.Map<T.AssetId, Nat> = Map.empty();
      // temporary lists of newly placed/cancelled orders
      type OrdersDelta = {
        var placed : PureList.List<(?T.OrderId, T.Order)>;
        var isOrderCancelled : (assetId : T.AssetId, orderId : T.OrderId) -> Bool;
      };
      let asksDelta : OrdersDelta = {
        var placed = null;
        var isOrderCancelled = func(_, _) = false;
      };
      let bidsDelta : OrdersDelta = {
        var placed = null;
        var isOrderCancelled = func(_, _) = false;
      };

      // array of functions which will write all changes to the state
      var cancellationCommitActions : PureList.List<() -> [T.CancellationResult]> = null;
      let placementCommitActions = VarArray.repeat<() -> T.PlaceOrderResult>(func() = (0, #placed), placements.size());

      let newPushNotifications : List.List<(Principal, T.PushNotification)> = List.empty();

      // update temporary balances: add unlocked credits for each cancelled order
      func affectNewBalancesWithCancellation(ordersService : OrderServices.OrdersService, order : T.Order) {
        let srcAssetId = ordersService.srcAssetId(order.assetId);
        let balance = switch (newBalances.get(srcAssetId)) {
          case (?b) b;
          case (null) user.accountBalance(srcAssetId);
        };
        newBalances.add(
          srcAssetId,
          (balance + ordersService.srcVolume(order.volume, order.price)),
        );
      };

      // prepare cancellation of all orders by type (ask or bid)
      func prepareBulkCancellation(ordersService : OrderServices.OrdersService) {
        let userOrderBook = user.getOrderBook(ordersService.kind);
        for ((orderId, order) in userOrderBook.map.entries()) {
          affectNewBalancesWithCancellation(ordersService, order);
        };
        cancellationCommitActions := PureList.pushFront<() -> [T.CancellationResult]>(
          cancellationCommitActions,
          func() {
            let ret : List.List<T.CancellationResult> = List.empty();
            for (orderId in userOrderBook.map.keys().toArray().values()) {
              let ?order = ordersService.cancel(user, orderId) else Prim.trap("Can never happen");
              ret.add((orderId, order.assetId, order.orderBookType, order.volume, order.price));
            };
            ret.toArray();
          },
        );
      };

      // prepare cancellation of all orders by given filter function by type (ask or bid)
      func prepareBulkCancellationWithFilter(ordersService : OrderServices.OrdersService, isCancel : (assetId : T.AssetId, orderId : T.OrderId) -> Bool) {
        // TODO can be optimized: cancelOrderInternal searches for order by it's id with linear complexity
        let userOrderBook = user.getOrderBook(ordersService.kind);
        let orderIds : List.List<T.OrderId> = List.empty();
        for ((orderId, order) in userOrderBook.map.entries()) {
          if (isCancel(order.assetId, orderId)) {
            affectNewBalancesWithCancellation(ordersService, order);
            orderIds.add(orderId);
          };
        };
        cancellationCommitActions := PureList.pushFront<() -> [T.CancellationResult]>(
          cancellationCommitActions,
          func() {
            let ret : List.List<T.CancellationResult> = List.empty();
            for (orderId in orderIds.values()) {
              let ?order = ordersService.cancel(user, orderId) else Prim.trap("Can never happen");
              ret.add((orderId, order.assetId, order.orderBookType, order.volume, order.price));
            };
            List.toArray(ret);
          },
        );
      };

      switch (cancellations) {
        case (null) {};
        case (?#all(null)) {
          asksDelta.isOrderCancelled := func(_, _) = true;
          bidsDelta.isOrderCancelled := func(_, _) = true;
          prepareBulkCancellation(asks);
          prepareBulkCancellation(bids);
        };
        case (?#all(?aids)) {
          asksDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(assetId, _) = Array.find<Nat>(aids, func(x) = x == assetId) |> not Option.isNull(_);
          prepareBulkCancellationWithFilter(asks, asksDelta.isOrderCancelled);
          prepareBulkCancellationWithFilter(bids, bidsDelta.isOrderCancelled);
        };
        case (?#orders(orders)) {
          let cancelledAsks : Map.Map<T.OrderId, ()> = Map.empty();
          let cancelledBids : Map.Map<T.OrderId, ()> = Map.empty();
          asksDelta.isOrderCancelled := func(_, orderId) = cancelledAsks.get(orderId) |> not Option.isNull(_);
          bidsDelta.isOrderCancelled := func(_, orderId) = cancelledBids.get(orderId) |> not Option.isNull(_);

          let assetIdSet : Map.Map<T.AssetId, Nat> = Map.empty();
          for (i in orders.keys()) {
            let (ordersService, orderId, cancelledTree) = switch (orders[i]) {
              case (#ask orderId) (asks, orderId, cancelledAsks);
              case (#bid orderId) (bids, orderId, cancelledBids);
            };
            let ?oldOrder = user.findOrder(ordersService.kind, orderId) else return #err(#cancellation({ index = i; error = #UnknownOrder }));
            affectNewBalancesWithCancellation(ordersService, oldOrder);
            cancelledTree.add(orderId, ());
            cancellationCommitActions := PureList.pushFront<() -> [T.CancellationResult]>(
              cancellationCommitActions,
              func() {
                let ?order = ordersService.cancel(user, orderId) else return [];
                [(orderId, order.assetId, order.orderBookType, order.volume, order.price)];
              },
            );
            assetIdSet.add(oldOrder.assetId, i);
          };
        };
      };

      // validate and prepare placements
      let assetIdSet : Map.Map<T.AssetId, Nat> = Map.empty();
      for (i in placements.keys()) {
        let (ordersService, (assetId, orderBookType, volume, rawPrice), ordersDelta, oppositeOrdersDelta) = switch (placements[i]) {
          case (#ask(args)) (asks, args, asksDelta, bidsDelta);
          case (#bid(args)) (bids, args, bidsDelta, asksDelta);
        };
        // validate asset id
        if (assetId == auction.quoteAssetId or assetId >= auction.assets.nAssets()) return #err(#placement({ index = i; error = #UnknownAsset }));

        // validate order volume and price
        let asset = auction.assets.getAsset(assetId);
        let ?price = roundPriceDigits(rawPrice) else return #err(#placement({ index = i; error = #PriceDigitsOverflow({ maxDigits = priceMaxDigits }) }));

        if (ordersService.isOrderLow(assetId, asset, volume, price)) return #err(#placement({ index = i; error = #TooLowOrder }));

        let baseVolumeStep = getBaseVolumeStep(price);
        if (volume % baseVolumeStep != 0) return #err(#placement({ index = i; error = #VolumeStepViolated({ baseVolumeStep }) }));

        // validate user credit
        let srcAssetId = ordersService.srcAssetId(assetId);
        let chargeAmount = ordersService.srcVolume(volume, price);
        let ?chargeAcc = user.getAccount(srcAssetId) else return #err(#placement({ index = i; error = #NoCredit }));
        let balance = switch (newBalances.get(srcAssetId)) {
          case (?b) b;
          case (null) chargeAcc.balance();
        };
        if (balance < chargeAmount) {
          return #err(#placement({ index = i; error = #NoCredit }));
        };
        newBalances.add(srcAssetId, (balance - chargeAmount) : Nat);

        // build list of placed orders + orders to be placed during this call
        func buildOrdersList(user : T.User, kind : { #ask; #bid }, delta : OrdersDelta) : Iter.Iter<(?T.OrderId, T.Order)> = user.getOrderBook(kind).map
        |> _.entries()
        |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o))
        |> Iter.concat<(?T.OrderId, T.Order)>(_, PureList.values(delta.placed));

        // validate conflicting orders
        for ((orderId, order) in buildOrdersList(user, ordersService.kind, ordersDelta)) {
          if (
            order.assetId == assetId and price == order.price and (
              switch (orderId) {
                case (?oid) not ordersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(ordersService.kind, orderId) }));
          };
        };

        let oppositeOrderManager = switch (ordersService.kind) {
          case (#ask) { bids };
          case (#bid) { asks };
        };
        for ((oppOrderId, oppOrder) in buildOrdersList(user, oppositeOrderManager.kind, oppositeOrdersDelta)) {
          if (
            oppOrder.assetId == assetId and ordersService.isOppositeOrderConflicts(price, oppOrder.price) and (
              switch (oppOrderId) {
                case (?oid) not oppositeOrdersDelta.isOrderCancelled(assetId, oid);
                case (null) true;
              }
            )
          ) {
            return #err(#placement({ index = i; error = #ConflictingOrder(oppositeOrderManager.kind, oppOrderId) }));
          };
        };

        let order : T.Order = {
          userPrincipal = p;
          userId = userIndex;
          assetId;
          orderBookType;
          price;
          var volume = volume;
        };
        ordersDelta.placed := PureList.pushFront(ordersDelta.placed, (null, order));

        placementCommitActions[i] := func() {
          let orderId = auction.ordersCounter;
          auction.ordersCounter += 1;
          switch (order.orderBookType, ordersService.place(user, chargeAcc, asset, orderId, order)) {
            case (#immediate, 0) {
              let ?executeFunc = executeImmediateOrderBooks else Prim.trap("execute function was not set");
              let executionResults = executeFunc(order.assetId, ordersService.kind);
              if (executionResults.size() > 0) {
                for ((price, volume, fulfilledOrders) in Array.values(executionResults)) {
                  for ({ order; baseVolume; quoteVolume; isPartial; kind } in PureList.values(fulfilledOrders)) {
                    if (order.userPrincipal != p and auction.users.atIndex(order.userId).userSettings.pushNotificationsEnabled) {
                      List.add(
                        newPushNotifications,
                        (
                          order.userPrincipal,
                          #orderFulfilled({
                            assetId;
                            kind;
                            price;
                            baseVolume;
                            quoteVolume;
                            isPartial;
                          }),
                        ),
                      );
                    };
                  };
                };
                (orderId, #executed(Array.map(executionResults, func(price, volume, _) = (price, volume))));
              } else {
                (orderId, #placed);
              };
            };
            case (_) (orderId, #placed);
          };
        };
        assetIdSet.add(assetId, i);
      };

      // commit changes, return results
      let retCancellations : List.List<T.CancellationResult> = List.empty();
      for (cancel in PureList.values(cancellationCommitActions)) {
        for (c in cancel().values()) {
          List.add(retCancellations, c);
        };
      };
      let retPlacements = Array.tabulate<T.PlaceOrderResult>(placementCommitActions.size(), func(i) = placementCommitActions[i]());

      if (List.size(retCancellations) > 0 or placements.size() > 0) {
        user.accountRevision += 1;
        user.loyaltyPoints += (List.size(retCancellations) + placements.size()) * C.LOYALTY_REWARD.ORDER_MODIFICATION;
      };

      if (placements.size() > 0) {
        let oldRecord = auction.users.participantsArchive.swap(p, { lastOrderPlacement = Prim.time() });
        switch (oldRecord) {
          case (null) auction.users.participantsArchiveSize += 1;
          case (_) {};
        };
      };

      for (n in List.values(newPushNotifications)) {
        stagePushNotification(n);
      };

      #ok(List.toArray(retCancellations), retPlacements);
    };

    public func manageDarkOrderBooks(
      p : Principal,
      userIndex : Nat,
      placements : [(assetId : T.AssetId, data : ?T.EncryptedOrderBook)],
      expectedAccountRevision : ?Nat,
    ) : R.Result<[?T.EncryptedOrderBook], { #AccountRevisionMismatch; #NoCredit }> {
      let user = auction.users.atIndex(userIndex);
      let ret = VarArray.repeat<?T.EncryptedOrderBook>(null, placements.size());
      switch (expectedAccountRevision) {
        case (?rev) {
          if (rev != user.accountRevision) {
            return #err(#AccountRevisionMismatch);
          };
        };
        case (null) {};
      };
      let ?quoteAccount = user.getAccount(auction.quoteAssetId) else return #err(#NoCredit);
      var newDarkOrderBooksPlaced : Int = 0;
      for ((assetId, newData) in placements.values()) {
        switch (newData, user.findDarkOrderBook(assetId)) {
          case (?_, null) newDarkOrderBooksPlaced += 1;
          case (null, ?_) newDarkOrderBooksPlaced -= 1;
          case (_) {};
        };
      };
      if (newDarkOrderBooksPlaced > 0) {
        let (locked, _) = quoteAccount.lockCredit(Int.abs(newDarkOrderBooksPlaced) * C.DARK_ORDER_BOOK_LOCK_AMOUNT);
        if (not locked) {
          return #err(#NoCredit);
        };
      } else if (newDarkOrderBooksPlaced < 0) {
        ignore quoteAccount.unlockCredit(Int.abs(newDarkOrderBooksPlaced) * C.DARK_ORDER_BOOK_LOCK_AMOUNT);
      };
      for (i in placements.keys()) {
        let (assetId, data) = placements[i];
        let asset = auction.assets.getAsset(assetId);
        ignore asset.putDarkOrderBook(p, data);
        let oldValue = user.putDarkOrderBook(assetId, data);
        ret[i] := oldValue;
      };
      #ok(VarArray.toArray(ret));
    };

    public func processDarkOrderBooks(assetId : T.AssetId, asset : T.Asset) : (asks : PureList.List<T.Order>, bids : PureList.List<T.Order>) {
      if (asset.darkOrderBooks.encrypted.isEmpty()) return (null, null);
      let ?decryptedOrderBooks = asset.darkOrderBooks.decrypted else Prim.trap("Dark order books were not decrypted");
      var asksQueue : PureList.List<T.Order> = null;
      var bidsQueue : PureList.List<T.Order> = null;
      label l for ((userPrincipal, orders) in decryptedOrderBooks.values()) {
        let ?userIndex = auction.users.getIndex(userPrincipal) else continue l;
        let user = auction.users.atIndex(userIndex);
        let ?quoteAccount = user.getAccount(auction.quoteAssetId) else Prim.trap("Can never happen");
        ignore quoteAccount.unlockCredit(C.DARK_ORDER_BOOK_LOCK_AMOUNT);
        // we do not acutally lock funds for encrypted orders, because we should then unlock them for all the encrypted orders, even not fulfilled
        // so we just check that user has enough funds for them
        let baseAccount = user.getAccount(assetId);
        var quoteToLock = 0;
        var baseToLock = 0;
        label il for ({ kind; price; volume } in orders.values()) {
          let ordersService = (switch (kind) { case (#ask) { asks }; case (#bid) { bids } });
          let order : T.Order = {
            userPrincipal;
            userId = userIndex;
            assetId;
            orderBookType = #delayed;
            price;
            var volume = volume;
          };
          let lockVolume = ordersService.srcVolume(order.volume, order.price);
          let lockSuccess = switch (kind) {
            case (#ask) {
              switch (baseAccount) {
                case (null) false;
                case (?ba) {
                  if (baseToLock + lockVolume + ba.lockedCredit <= ba.credit) {
                    baseToLock += lockVolume;
                    true;
                  } else { false };
                };
              };
            };
            case (#bid) {
              if (quoteToLock + lockVolume + quoteAccount.lockedCredit <= quoteAccount.credit) {
                quoteToLock += lockVolume;
                true;
              } else { false };
            };
          };
          if (not lockSuccess) continue il;
          switch (kind) {
            case (#ask) {
              let (queueUpd, _) = asksQueue.insert(order, func(a, b) = Float.compare(b.price, a.price));
              asksQueue := queueUpd;
            };
            case (#bid) {
              let (queueUpd, _) = bidsQueue.insert(order, func(a, b) = Float.compare(a.price, b.price));
              bidsQueue := queueUpd;
            };
          };
        };
        ignore user.putDarkOrderBook(assetId, null);
      };
      asset.darkOrderBooks.encrypted := Map.empty();
      asset.darkOrderBooks.decrypted := null;
      (asksQueue, bidsQueue);
    };

  };
};
