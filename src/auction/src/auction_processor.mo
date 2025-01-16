import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Prim "mo:prim";

import { clear } "mo:auction";

import Orders "./orders";
import T "./types";

module {

  public func clearAuction(asks : Orders.CombinedOrderBookService, bids : Orders.CombinedOrderBookService) : ?(price : Float, volume : Nat) {
    let mapOrders = func(orders : Iter.Iter<(T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> {
      Iter.map<(T.OrderId, T.Order), (Float, Nat)>(orders, func(_, order) = (order.price, order.volume));
    };
    clear(mapOrders(asks.toIter()), mapOrders(bids.toIter()), Float.less);
  };

  public func processAuction(sessionNumber : Nat, asks : Orders.CombinedOrderBookService, bids : Orders.CombinedOrderBookService) : (price : Float, volume : Nat, surplus : Nat) {

    let ?(price, dealVolume) = clearAuction(asks, bids) else return (0.0, 0, 0);

    var quoteSurplus : Int = 0;

    var dealVolumeLeft = dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = asks.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (volume, quoteVol) = asks.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= volume;
      quoteSurplus -= quoteVol;
    };

    dealVolumeLeft := dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = bids.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (volume, quoteVol) = bids.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= volume;
      quoteSurplus += quoteVol;
    };

    assert quoteSurplus >= 0;
    (price, dealVolume, Int.abs(quoteSurplus));
  };

};
