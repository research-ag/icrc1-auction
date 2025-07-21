import Float "mo:base/Float";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Prim "mo:prim";

import { clear } "mo:auction";

import Orders "./orders";
import T "./types";

module {

  public func clearAuction(asks : Orders.OrderBookService, bids : Orders.OrderBookService) : ?(price : Float, volume : Nat) {

    func denominateVolumeInBaseAsset(volume : Nat, unitPrice : Float) : Nat = Float.fromInt(volume) / unitPrice
    |> Float.floor(_)
    |> Int.abs(Float.toInt(_));

    clear(
      asks.queue()
      |> List.toIter(_)
      |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, order.volume)),
      bids.queue()
      |> List.toIter(_)
      |> Iter.map<(T.OrderId, T.Order), (Float, Nat)>(_, func(_, order) = (order.price, denominateVolumeInBaseAsset(order.volume, order.price))),
      Float.less,
    );
  };

  public func processAuction(sessionNumber : Nat, asks : Orders.OrderBookService, bids : Orders.OrderBookService) : (price : Float, volume : Nat, surplus : Nat) {

    let ?(price, dealVolume) = clearAuction(asks, bids) else return (0.0, 0, 0);

    var quoteSurplus : Int = 0;

    var dealVolumeLeft = dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = asks.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVol, quoteVol) = asks.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVol;
      quoteSurplus -= quoteVol;
    };

    dealVolumeLeft := dealVolume;
    while (dealVolumeLeft > 0) {
      let ?(orderId, order) = bids.nextOrder() else Prim.trap("Can never happen: list shorter than before");
      let (baseVol, quoteVol) = bids.fulfilOrder(sessionNumber, orderId, order, dealVolumeLeft, price);
      dealVolumeLeft -= baseVol;
      quoteSurplus += quoteVol;
    };

    assert quoteSurplus >= 0;
    (price, dealVolume, Int.abs(quoteSurplus));
  };

};
