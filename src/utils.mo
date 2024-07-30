import Iter "mo:base/Iter";
import Prim "mo:prim";
import R "mo:base/Result";

import Vec "mo:vector";

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

  public func sliceIter<T>(iter : Iter.Iter<T>, limit : Nat, skip : Nat) : [T] {
    var i = 0;
    while (i < skip) {
      let ?_ = iter.next() else return [];
      i += 1;
    };
    let ret : Vec.Vector<T> = Vec.new();
    i := 0;
    label l while (i < limit) {
      let ?x = iter.next() else break l;
      Vec.add(ret, x);
      i += 1;
    };
    Vec.toArray(ret);
  };
};
