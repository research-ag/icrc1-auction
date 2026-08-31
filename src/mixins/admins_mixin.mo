import Error "mo:core/Error";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Set "mo:core/Set";

import Prim "mo:prim";

/// Mixin that adds admin functionality
mixin (defaultAdmin : ?Principal) {
  var admins : Set.Set<Principal> = Set.empty();

  switch (Set.size(admins)) {
    case (0) {
      Set.add(admins, Principal.compare, Option.get(defaultAdmin, Principal.fromText("2vxsx-fae")));
    };
    case (_) {};
  };

  private func assertAdminAccess(principal : Principal) : async* () {
    if (not Set.contains(admins, Principal.compare, principal)) {
      throw Error.reject("No Access for this principal " # Principal.toText(principal));
    };
  };

  private func assertAdminAccessSync(principal : Principal) : () {
    if (not Set.contains(admins, Principal.compare, principal)) {
      Prim.trap("No Access for this principal " # Principal.toText(principal));
    };
  };

  public query func listAdmins() : async [Principal] = async Set.toArray(admins);

  public shared ({ caller }) func addAdmin(principal : Principal) : async () {
    await* assertAdminAccess(caller);
    Set.add(admins, Principal.compare, principal);
  };

  public shared ({ caller }) func removeAdmin(principal : Principal) : async () {
    await* assertAdminAccess(caller);
    if (Principal.equal(principal, caller)) {
      throw Error.reject("Cannot remove yourself from admins");
    };
    Set.remove(admins, Principal.compare, principal);
  };
};
