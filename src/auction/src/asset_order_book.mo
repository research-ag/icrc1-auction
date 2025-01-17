import Float "mo:base/Float";
import List "mo:base/List";
import O "mo:base/Order";

import T "./types";
import PriorityQueue "./priority_queue";

module OrderBook {

  type OrderId = T.OrderId;
  type Order = T.Order;
  type AssetOrderBook = T.AssetOrderBook;

  public func nil(kind : { #ask; #bid }) : AssetOrderBook = {
    kind;
    var queue = List.nil();
    var size = 0;
    var totalVolume = 0;
  };

  public func clear(orderBook : AssetOrderBook) {
    orderBook.queue := List.nil();
    orderBook.size := 0;
    orderBook.totalVolume := 0;
  };

  public func comparePriority(kind : { #ask; #bid }) : (a : (OrderId, Order), b : (OrderId, Order)) -> O.Order = switch (kind) {
    case (#ask) func(a : (OrderId, Order), b : (OrderId, Order)) = Float.compare(b.1.price, a.1.price);
    case (#bid) func(a : (OrderId, Order), b : (OrderId, Order)) = Float.compare(a.1.price, b.1.price);
  };

  public func insert(orderBook : AssetOrderBook, orderId : OrderId, order : Order) {
    orderBook.queue := PriorityQueue.insert<(OrderId, Order)>(
      orderBook.queue,
      (orderId, order),
      comparePriority(orderBook.kind),
    );
    orderBook.size += 1;
    orderBook.totalVolume += order.volume;
  };

  // call this after updating order volume
  // WARNING: not a safe operation
  public func deductVolume(orderBook : AssetOrderBook, amount : Nat) {
    orderBook.totalVolume -= amount;
  };

  public func delete(orderBook : AssetOrderBook, orderId : OrderId) : ?Order {
    let (upd, oldValue) = PriorityQueue.findOneAndDelete<(OrderId, Order)>(orderBook.queue, func(id, _) = id == orderId);
    let ?(_, existingOrder) = oldValue else return null;
    orderBook.queue := upd;
    orderBook.size -= 1;
    orderBook.totalVolume -= existingOrder.volume;
    ?existingOrder;
  };

};
