import Array "mo:core/Array";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import PureList "mo:core/pure/List";
import Nat "mo:core/Nat";
import Option "mo:core/Option";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import Queue "mo:core/Queue";
import R "mo:core/Result";
import Map "mo:core/Map";
import VarArray "mo:core/VarArray";
import List "mo:core/List";

import Account "./account";
import AssetsStorage "./assets_storage";
import Asset "./asset";
import C "./constants";
import User "./user";
import UsersStorage "./users_storage";

import T "./types";
import AssetOrderBook "asset_order_book";
import PriorityQueue "./models/priority_queue";
import U "./utils";

module {

  /// helper class to work with all orders of given asset
  public class OrderBookExecutionService(
    service : OrdersService,
    asset : T.Asset,
    orderBookType : {
      #immediate;
      #combined : { encryptedOrdersQueue : PureList.List<T.Order> };
    },
  ) {

    public func toIter() : Iter.Iter<(?T.OrderId, T.Order)> {
      switch (orderBookType) {
        // Note: for immediate order book we always take only the first entry, because clearing happens for each ask-bid pair separately
        case (#immediate) {
          service.assetOrderBook(asset, #immediate).queue
          |> PureList.values(_)
          |> Iter.take(_, 1)
          |> Iter.map<(T.OrderId, T.Order), (?T.OrderId, T.Order)>(_, func(oid, o) = (?oid, o));
        };
        case (#combined { encryptedOrdersQueue }) {

          var delayedCursor = service.assetOrderBook(asset, #delayed).queue;
          var immediateCursor = service.assetOrderBook(asset, #immediate).queue;
          var encryptedCursor = encryptedOrdersQueue;

          object {
            public func next() : ?(?T.OrderId, T.Order) {
              var pickFrom : {
                #delayed : (T.OrderId, T.Order);
                #immediate : (T.OrderId, T.Order);
                #encrypted : T.Order;
                #none;
              } = #none;
              switch (delayedCursor, immediateCursor) {
                case (?(d, _), ?(i, _)) switch (AssetOrderBook.comparePriority(service.kind)(d, i)) {
                  case (#less) pickFrom := #immediate(i);
                  case (_) pickFrom := #delayed(d);
                };
                case (?(item, _), null) pickFrom := #delayed(item);
                case (null, ?(item, _)) pickFrom := #immediate(item);
                case (_) {};
              };
              switch (encryptedCursor, pickFrom) {
                case (?(order, _), #none) pickFrom := #encrypted(order);
                case (?(order, _), #delayed x or #immediate x) switch (AssetOrderBook.comparePriority(service.kind)((0, order), x)) {
                  case (#less) {};
                  case (_) pickFrom := #encrypted(order);
                };
                case (_) {};
              };
              switch (pickFrom) {
                case (#immediate(oid, order)) {
                  let ?c = immediateCursor else Prim.trap("");
                  immediateCursor := c.1;
                  ?(?oid, order);
                };
                case (#delayed(oid, order)) {
                  let ?c = delayedCursor else Prim.trap("");
                  delayedCursor := c.1;
                  ?(?oid, order);
                };
                case (#encrypted(order)) {
                  let ?c = encryptedCursor else Prim.trap("");
                  encryptedCursor := c.1;
                  ?(null, order);
                };
                case (#none) null;
              };
            };
          };
        };
      };
    };

    public func nextOrder() : ?(?T.OrderId, T.Order) = toIter().next();

    public func fulfilOrder(sessionNumber : Nat, orderId : ?T.OrderId, order : T.Order, maxVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat, isPartial : Bool) {
      service.fulfil(asset, sessionNumber, orderId, order, maxVolume, price);
    };

    public func totalVolume() : Nat {
      switch (orderBookType) {
        case (#immediate) service.assetOrderBook(asset, #immediate).totalVolume;
        case (#combined _) service.assetOrderBook(asset, #delayed).totalVolume + service.assetOrderBook(asset, #immediate).totalVolume;
      };
    };
  };

  /// A class with functionality to operate on all orders of the given type across the auction
  public class OrdersService(
    assets : AssetsStorage.AssetsStorage,
    users : UsersStorage.UsersStorage,
    quoteAssetId : T.AssetId,
    minQuoteVolume : Nat,
    minAskVolume : (T.AssetId, T.Asset) -> Int,
    kind_ : { #ask; #bid },
  ) = self {

    public func createOrderBookExecutionService(
      asset : T.Asset,
      orderBookType : {
        #immediate;
        #combined : { encryptedOrdersQueue : PureList.List<T.Order> };
      },
    ) : OrderBookExecutionService = OrderBookExecutionService(self, asset, orderBookType);

    public let kind : { #ask; #bid } = kind_;

    func denominateVolumeInQuoteAsset(volume : Nat, unitPrice : Float) : Nat {
      if (kind == #ask) {
        U.multiplyNatByFloatMin(volume, unitPrice);
      } else {
        U.multiplyNatByFloatMax(volume, unitPrice);
      };
    };

    // returns asset id, which will be debited from user upon placing order
    public func srcAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) orderAssetId;
      case (#bid) quoteAssetId;
    };

    // returns amount to debit from "srcAssetId" account
    public func srcVolume(volume : Nat, price : Float) : Nat = switch (kind) {
      case (#ask) volume;
      case (#bid) denominateVolumeInQuoteAsset(volume, price);
    };

    // returns asset id, which will be credited to user when fulfilling order
    public func destAssetId(orderAssetId : T.AssetId) : T.AssetId = switch (kind) {
      case (#ask) quoteAssetId;
      case (#bid) orderAssetId;
    };

    // returns amount to credit to "destAssetId" account
    public func destVolume(volume : Nat, price : Float) : Nat = switch (kind) {
      case (#ask) denominateVolumeInQuoteAsset(volume, price);
      case (#bid) volume;
    };

    // validation
    public func isOrderLow(orderAssetId : T.AssetId, orderAssetInfo : T.Asset, volume : Nat, price : Float) : Bool = switch (kind) {
      case (#ask) price <= 0.0 or volume < minAskVolume(orderAssetId, orderAssetInfo);
      case (#bid) denominateVolumeInQuoteAsset(volume, price) < minQuoteVolume;
    };

    public func isOppositeOrderConflicts(orderPrice : Float, oppositeOrderPrice : Float) : Bool = switch (kind) {
      case (#ask) oppositeOrderPrice >= orderPrice;
      case (#bid) oppositeOrderPrice <= orderPrice;
    };

    public func assetOrderBook(asset : T.Asset, orderBookType : T.OrderBookType) : T.AssetOrderBook = asset.getOrderBook(kind, orderBookType);

    public func place(user : T.User, accountToCharge : T.Account, asset : T.Asset, orderId : T.OrderId, order : T.Order) : Nat {
      // charge user credits
      let (success, _) = accountToCharge.lockCredit(srcVolume(order.volume, order.price));
      assert success;
      // insert into order lists
      user.putOrder(kind, orderId, order);
      asset.putOrder(kind, orderId, order);
    };

    public func cancel(user : T.User, orderId : T.OrderId) : ?T.Order {
      // find and remove from order lists
      let ?existingOrder = user.deleteOrder(kind, orderId) else return null;
      assets.getAsset(existingOrder.assetId) |> _.deleteOrder(kind, existingOrder.orderBookType, orderId);
      // return deposit to user
      let ?sourceAcc = user.getAccount(srcAssetId(existingOrder.assetId)) else Prim.trap("Can never happen");
      let (success, _) = sourceAcc.unlockCredit(srcVolume(existingOrder.volume, existingOrder.price));
      assert success;

      ?existingOrder;
    };

    // bid: source = quote, dest = base
    // ask: source = base, dest = quote
    public func fulfil(asset : T.Asset, sessionNumber : Nat, orderId : ?T.OrderId, order : T.Order, maxVolume : Nat, price : Float) : (volume : Nat, quoteVol : Nat, isPartial : Bool) {
      let ?sourceAcc = users.atIndex(order.userId).getAccount(srcAssetId(order.assetId)) else Prim.trap("Can never happen");

      switch (orderId) {
        case (?oid) sourceAcc.unlockCredit(srcVolume(order.volume, order.price)) |> (assert _.0);
        case (null) {};
      };

      let isPartial = maxVolume < order.volume;
      let baseVolume = Nat.min(maxVolume, order.volume); // = executed volume

      // source and destination volumes
      let srcVol = switch (isPartial, kind) {
        case (true, #bid) U.multiplyNatByFloatMin(baseVolume, price);
        case (_) srcVolume(baseVolume, price);
      };
      let destVol = destVolume(baseVolume, price);

      // adjust orders
      switch (orderId) {
        case (?oid) {
          if (isPartial) {
            sourceAcc.lockCredit(srcVolume(order.volume - baseVolume, order.price)) |> (assert _.0); // re-lock credit
            asset.deductOrderVolume(kind, order, baseVolume); // shrink order
          } else {
            users.atIndex(order.userId).deleteOrder(kind, oid) |> (ignore _); // delete order
            asset.deleteOrder(kind, order.orderBookType, oid); // delete order
          };
        };
        case (null) {};
      };

      // debit at source
      sourceAcc.deductCredit(srcVol) |> (assert _.0);
      ignore users.atIndex(order.userId).deleteAccountIfEmpty(srcAssetId(order.assetId));

      // credit at destination
      let acc = users.atIndex(order.userId).getOrCreateAccount(destAssetId(order.assetId));
      ignore acc.appendCredit(destVol);

      List.add(users.atIndex(order.userId).transactionHistory, (Prim.time(), sessionNumber, kind, order.assetId, baseVolume, price));

      let quoteVolume = switch (kind) {
        case (#ask) destVol;
        case (#bid) srcVol;
      };

      if (not isPartial) {
        asset.totalExecutedOrders += 1;
      };

      let user = users.atIndex(order.userId);
      user.accountRevision += 1;
      user.loyaltyPoints += C.LOYALTY_REWARD.ORDER_EXECUTION + quoteVolume / C.LOYALTY_REWARD.ORDER_VOLUME_DIVISOR;
      switch (kind) {
        case (#ask) asset.totalExecutedVolumeQuote += quoteVolume;
        case (#bid) asset.totalExecutedVolumeBase += baseVolume;
      };

      (baseVolume, quoteVolume, isPartial);
    };
  };

};
