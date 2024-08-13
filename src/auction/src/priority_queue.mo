import List "mo:base/List";
import Order "mo:base/Order";

module {

  public type PriorityQueue<T> = List.List<T>;

  // inserts item to the queue, places it after all items with higher or equal priority
  public func insert<T>(queue : PriorityQueue<T>, item : T, comparePriority : (T, T) -> Order.Order) : PriorityQueue<T> {
    switch queue {
      case null { ?(item, null) };
      case (?(h, tail)) {
        switch (comparePriority(h, item)) {
          case (#less) ?(item, queue);
          case (_) insert<T>(tail, item, comparePriority) |> ?(h, _);
        };
      };
    };
  };

  // goes through list, finds one needed element and removes it if found. Returns updated list and flag is item was found and deleted
  public func findOneAndDelete<T>(queue : PriorityQueue<T>, f : T -> Bool) : (PriorityQueue<T>, ?T) {
    switch queue {
      case null { (null, null) };
      case (?(h, t)) {
        if (f(h)) {
          (t, ?h);
        } else {
          findOneAndDelete<T>(t, f) |> (?(h, _.0), _.1);
        };
      };
    };
  };

};
