import List "mo:base/List";
import Prim "mo:prim";
import R "mo:base/Result";

module {

  // goes through list, finds one needed element and removes it if found. Returns updated list and flag is item was found and deleted
  public func listFindOneAndDelete<T>(list : List.List<T>, f : T -> Bool) : (List.List<T>, Bool) {
    switch list {
      case null { (null, false) };
      case (?(h, t)) {
        if (f(h)) {
          (t, true);
        } else {
          listFindOneAndDelete<T>(t, f) |> (?(h, _.0), _.1);
        };
      };
    };
  };

  // goes through list, finds first element for which f will return true, and inserts provided element BEFORE it
  public func insertWithPriority<T>(list : List.List<T>, item : T, f : T -> Bool) : List.List<T> {
    switch list {
      case null { ?(item, null) };
      case (?(h, t)) {
        if (f(h)) {
          ?(item, list);
        } else {
          insertWithPriority<T>(t, item, f) |> ?(h, _);
        };
      };
    };
  };

  public func unwrapUninit<T>(o : ?T) : T = requireMsg(o, "Not initialized");

  public func requireMsg<T>(opt : ?T, message : Text) : T {
    switch (opt) {
      case (?o) o;
      case (null) Prim.trap(message);
    };
  };

  public func requireOk<T>(res : R.Result<T, Any>) : T = requireOkMsg(res, "Required result is #err");

  public func requireOkMsg<T>(res : R.Result<T, Any>, message : Text) : T {
    switch (res) {
      case (#ok ok) ok;
      case (_) Prim.trap(message);
    };
  };
};
