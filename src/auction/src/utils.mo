import Iter "mo:base/Iter";
import List "mo:base/List";

import Vec "mo:vector";

module {

  public func sliceList<T>(list : List.List<T>, limit : Nat, skip : Nat) : [T] {
    var tail = list;
    var i = 0;
    while (i < skip) {
      let ?(_, next) = tail else return [];
      tail := next;
      i += 1;
    };
    let ret : Vec.Vector<T> = Vec.new();
    i := 0;
    label l while (i < limit) {
      let ?(item, next) = tail else break l;
      Vec.add(ret, item);
      tail := next;
      i += 1;
    };
    Vec.toArray(ret);
  };

  public func sliceListWithFilter<T>(list : List.List<T>, f : (item : T) -> Bool, limit : Nat, skip : Nat) : [T] {
    var tail = list;
    var i = 0;
    while (i < skip) {
      let ?(item, next) = tail else return [];
      tail := next;
      if (f(item)) {
        i += 1;
      };
    };
    let ret : Vec.Vector<T> = Vec.new();
    i := 0;
    label l while (i < limit) {
      let ?(item, next) = tail else break l;
      if (f(item)) {
        Vec.add(ret, item);
        i += 1;
      };
      tail := next;
    };
    Vec.toArray(ret);
  };

  /** concat two iterables into one */
  public func iterConcat<T>(a : Iter.Iter<T>, b : Iter.Iter<T>) : Iter.Iter<T> {
    var aEnded : Bool = false;
    object {
      public func next() : ?T {
        if (aEnded) {
          return b.next();
        };
        let nextA = a.next();
        switch (nextA) {
          case (?val) ?val;
          case (null) {
            aEnded := true;
            b.next();
          };
        };
      };
    };
  };

};
