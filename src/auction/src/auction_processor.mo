import Float "mo:base/Float";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Prim "mo:prim";

import { clear } "mo:auction";

import Orders "./orders";
import T "./types";

module {

  public func processAuction(sessionNumber : Nat, asks : Orders.OrderBookService, bids : Orders.OrderBookService) : (price : Float, volume : Nat) {

    let mapOrders = func(orders : List.List<(T.OrderId, T.Order)>) : Iter.Iter<(Float, Nat)> = List.toIter(orders)
    |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume));

    let ?(price, dealVolume) = clear(mapOrders(asks.queue()), mapOrders(bids.queue()), Float.less) else return (0.0, 0);

    var dealVolumeLeft = dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = asks.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      dealVolumeLeft -= asks.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
    };

    dealVolumeLeft := dealVolume;
    label b while (dealVolumeLeft > 0) {
      let ?(orderId, order) = bids.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      dealVolumeLeft -= bids.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
    };

    (price, dealVolume);
  };

};
