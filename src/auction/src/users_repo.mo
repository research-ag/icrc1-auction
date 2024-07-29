import Prim "mo:prim";
import Principal "mo:base/Principal";
import RBTree "mo:base/RBTree";

import T "./types";

module {

  public class UsersRepo() {

    public var usersAmount : Nat = 0;
    public let users : RBTree.RBTree<Principal, T.UserInfo> = RBTree.RBTree<Principal, T.UserInfo>(Principal.compare);

    public func get(p : Principal) : ?T.UserInfo = users.get(p);

    public func getOrCreate(p : Principal) : T.UserInfo = switch (get(p)) {
      case (?info) info;
      case (null) {
        let data : T.UserInfo = {
          var currentAsks = null;
          var currentBids = null;
          var credits = null;
          var history = null;
        };
        let oldValue = users.replace(p, data);
        switch (oldValue) {
          case (?_) Prim.trap("Prevented user data overwrite");
          case (_) {};
        };
        usersAmount += 1;
        data;
      };
    };

  };

};
