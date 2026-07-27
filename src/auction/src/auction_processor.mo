import Float "mo:core/Float";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import PureList "mo:core/pure/List";
import Option "mo:core/Option";
import Prim "mo:prim";

import { clear } "mo:auction";

import OrderServices "./order_services";
import T "./types";

module {

  public type FulfilledOrder = {
    order : T.Order;
    baseVolume : Nat;
    quoteVolume : Nat;
    isPartial : Bool;
    kind : { #ask; #bid };
  };

  public type AuctionProcessingResult = {
    quoteSurplus : Nat;
    fulfilledOrders : PureList.List<FulfilledOrder>;
  };

  public func clearAuction(asks : OrderServices.OrderBookExecutionService, bids : OrderServices.OrderBookExecutionService) : (price : Float, volume : Nat) {
    let mapOrders = func(orders : Iter.Iter<(?T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> {
      Iter.map<(?T.OrderId, T.Order), (Float, Nat)>(orders, func(_, order) = (order.price, order.volume));
    };
    clear(mapOrders(asks.toIter()), mapOrders(bids.toIter()), Float.less) |> Option.get(_, (0.0, 0));
  };

  public func processAuction(sessionNumber : Nat, asks : OrderServices.OrderBookExecutionService, bids : OrderServices.OrderBookExecutionService, price : Float, dealVolume : Nat) : AuctionProcessingResult {
    var quoteSurplus : Int = 0;
    var dealVolumeLeft = dealVolume;
    var fulfilledOrders : PureList.List<FulfilledOrder> = null;

    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = asks.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVolume, quoteVolume, isPartial) = asks.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVolume;
      quoteSurplus -= quoteVolume;
      fulfilledOrders := PureList.pushFront(fulfilledOrders, { order; baseVolume; quoteVolume; isPartial; kind = #ask });
    };

    dealVolumeLeft := dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = bids.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVolume, quoteVolume, isPartial) = bids.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVolume;
      quoteSurplus += quoteVolume;
      fulfilledOrders := PureList.pushFront(fulfilledOrders, { order; baseVolume; quoteVolume; isPartial; kind = #bid });
    };

    assert quoteSurplus >= 0;
    {
      quoteSurplus = Int.abs(quoteSurplus);
      fulfilledOrders;
    };
  };

};
