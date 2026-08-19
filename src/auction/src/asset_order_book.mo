import Float "mo:core/Float";
import PureList "mo:core/pure/List";
import O "mo:core/Order";

import DecimalNat "mo:safe-financial-math/DecimalNat";

import T "./types";
import PriorityQueue "./models/priority_queue";

module OrderBook {

  type OrderId = T.OrderId;
  type Order = T.Order;
  type AssetOrderBook = T.AssetOrderBook;

  public func empty(kind : { #ask; #bid }) : AssetOrderBook = {
    kind;
    var queue = PureList.empty();
    var size = 0;
    var totalVolume = 0;
  };

  public func clear(orderBook : AssetOrderBook) {
    orderBook.queue := PureList.empty();
    orderBook.size := 0;
    orderBook.totalVolume := 0;
  };

  public func comparePriority(kind : { #ask; #bid }) : (a : (OrderId, Order), b : (OrderId, Order)) -> O.Order = switch (kind) {
    case (#ask) func(a : (OrderId, Order), b : (OrderId, Order)) = DecimalNat.compare(b.1.price, a.1.price);
    case (#bid) func(a : (OrderId, Order), b : (OrderId, Order)) = DecimalNat.compare(a.1.price, b.1.price);
  };

  public func insert(self : AssetOrderBook, orderId : OrderId, order : Order) : Nat {
    let (queueUpd, index) = self.queue.insert((orderId, order), comparePriority(self.kind));
    self.queue := queueUpd;
    self.size += 1;
    self.totalVolume += order.volume;
    index;
  };

  // call this after updating order volume
  // WARNING: not a safe operation
  public func deductVolume(self : AssetOrderBook, amount : Nat) {
    self.totalVolume -= amount;
  };

  public func delete(self : AssetOrderBook, orderId : OrderId) : ?Order {
    let (upd, oldValue) = self.queue.findOneAndDelete(func(id, _) = id == orderId);
    let ?(_, existingOrder) = oldValue else return null;
    self.queue := upd;
    self.size -= 1;
    self.totalVolume -= existingOrder.volume;
    ?existingOrder;
  };

};
