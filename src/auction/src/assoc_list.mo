import PureList "mo:core/pure/List";

// Minimal re-implementation of mo:core/AssocList, which has no direct
// equivalent in mo:core. Kept local since only `find`/`replace` are used
// across the auction module.
module {

  public type AssocList<K, V> = PureList.List<(K, V)>;

  public func find<K, V>(al : AssocList<K, V>, key : K, eq : (K, K) -> Bool) : ?V {
    switch al {
      case null null;
      case (?((k, v), tail)) if (eq(key, k)) ?v else find<K, V>(tail, key, eq);
    };
  };

  // Replace, add, or remove a key's value in the association list.
  // Returns the updated list and the previous value (if any).
  public func replace<K, V>(al : AssocList<K, V>, key : K, eq : (K, K) -> Bool, value : ?V) : (AssocList<K, V>, ?V) {
    switch al {
      case null {
        switch value {
          case null (null, null);
          case (?v) (?((key, v), null), null);
        };
      };
      case (?((k, v), tail)) {
        if (eq(key, k)) {
          switch value {
            case null (tail, ?v);
            case (?newV) (?((key, newV), tail), ?v);
          };
        } else {
          let (updTail, oldV) = replace<K, V>(tail, key, eq, value);
          (?((k, v), updTail), oldV);
        };
      };
    };
  };

};
