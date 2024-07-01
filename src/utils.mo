import Prim "mo:prim";
import R "mo:base/Result";

module {

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
