import AssocList "mo:base/AssocList";
import Text "mo:base/Text";

module {

  public type CallStatRecord = {
    var amount : Nat;
  };

  public type CallStats = {
    var map : AssocList.AssocList<Text, CallStatRecord>;
  };

  public func nil() : CallStats = { var map = null };

  public func logCall(stats : CallStats, key : Text) {
    let record = switch (AssocList.find(stats.map, key, Text.equal)) {
      case (?r) r;
      case (null) {
        let r : CallStatRecord = { var amount = 0 };
        let (upd, _) = AssocList.replace<Text, CallStatRecord>(stats.map, key, Text.equal, ?r);
        stats.map := upd;
        r;
      };
    };
    record.amount += 1;
  };

  public func getCallAmount(stats : CallStats, key : Text) : Nat {
    switch (AssocList.find(stats.map, key, Text.equal)) {
      case (?r) r.amount;
      case (null) 0;
    };
  };

};
