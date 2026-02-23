import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Option "mo:base/Option";
import Prim "mo:prim";

import { clear } "mo:auction";

import Orders "./orders";
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
    fulfilledOrders : List.List<FulfilledOrder>;
  };

  public func clearAuction(asks : Orders.OrderBookExecutionService, bids : Orders.OrderBookExecutionService) : (price : Float, volume : Nat) {
    let mapOrders = func(orders : Iter.Iter<(?T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> {
      Iter.map<(?T.OrderId, T.Order), (Float, Nat)>(orders, func(_, order) = (order.price, order.volume));
    };
    clear(mapOrders(asks.toIter()), mapOrders(bids.toIter()), Float.less) |> Option.get(_, (0.0, 0));
  };

  public func processAuction(sessionNumber : Nat, asks : Orders.OrderBookExecutionService, bids : Orders.OrderBookExecutionService, price : Float, dealVolume : Nat) : AuctionProcessingResult {
    var quoteSurplus : Int = 0;
    var dealVolumeLeft = dealVolume;
    var fulfilledOrders : List.List<FulfilledOrder> = null;

    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = asks.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVolume, quoteVolume, isPartial) = asks.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVolume;
      quoteSurplus -= quoteVolume;
      fulfilledOrders := List.push({ order; baseVolume; quoteVolume; isPartial; kind = #ask }, fulfilledOrders);
    };

    dealVolumeLeft := dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = bids.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVolume, quoteVolume, isPartial) = bids.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVolume;
      quoteSurplus += quoteVolume;
      fulfilledOrders := List.push({ order; baseVolume; quoteVolume; isPartial; kind = #bid }, fulfilledOrders);
    };

    assert quoteSurplus >= 0;
    {
      quoteSurplus = Int.abs(quoteSurplus);
      fulfilledOrders;
    };
  };

};
