import Error "mo:base/Error";
import Iter "mo:base/Iter";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import RBTree "mo:base/RBTree";

module Permissions {

  public type StableDataV1 = RBTree.Tree<Principal, ()>;

  public func defaultStableDataV1() : StableDataV1 = RBTree.RBTree<Principal, ()>(Principal.compare).share();

  public class Permissions(data : StableDataV1, defaultAdmin : ?Principal) {

    let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
    adminsMap.unshare(
      switch (RBTree.size(data)) {
        case (0) {
          let adminsMap = RBTree.RBTree<Principal, ()>(Principal.compare);
          let ?admin = defaultAdmin else Prim.trap("Admin not provided");
          adminsMap.put(admin, ());
          adminsMap.share();
        };
        case (_) data;
      }
    );

    public func listAdmins() : [Principal] = adminsMap.entries()
    |> Iter.map<(Principal, ()), Principal>(_, func((p, _)) = p)
    |> Iter.toArray(_);

    public func assertAdminAccess(principal : Principal) : async* () {
      if (adminsMap.get(principal) == null) {
        throw Error.reject("No Access for this principal " # Principal.toText(principal));
      };
    };

    public func assertAdminAccessSync(principal : Principal) : () {
      if (adminsMap.get(principal) == null) {
        Prim.trap("No Access for this principal " # Principal.toText(principal));
      };
    };

    public func addAdmin(principal : Principal) {
      adminsMap.put(principal, ());
    };

    public func removeAdmin(principal : Principal) : () {
      adminsMap.delete(principal);
    };

    public func share() : StableDataV1 = adminsMap.share();
  };
};
