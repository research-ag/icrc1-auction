import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";

import Account "./account";
import User "./user";
import T "./types";

module {

  public type UsersStorage = T.UsersStorage;

  public func empty() : UsersStorage = {
    usersList = List.empty();
    usersLookup = Map.empty();
    participantsArchive = Map.empty();
    var participantsArchiveSize = 0;

    var quoteSurplus = 0;
  };

  public func nUsers(self : UsersStorage) : Nat = self.usersList.size();

  public func nUsersWithCredits(self : UsersStorage) : Nat {
    var res : Nat = 0;
    for (user in self.usersList.values()) {
      if (not user.credits.isEmpty()) {
        res += 1;
      };
    };
    res;
  };

  public func nUsersWithActiveOrders(self : UsersStorage) : Nat {
    var res : Nat = 0;
    for (user in self.usersList.values()) {
      if (not user.asks.map.isEmpty() or not user.bids.map.isEmpty()) {
        res += 1;
      };
    };
    res;
  };

  public func nAccounts(self : UsersStorage) : Nat {
    var res : Nat = 0;
    for (user in self.usersList.values()) {
      res += user.credits.size();
    };
    res;
  };

  public func getByIndex(self : UsersStorage, idx : Nat) : ?User.User = self.usersList.get(idx);
  public func atIndex(self : UsersStorage, idx : Nat) : User.User = self.usersList.at(idx);

  public func getIndex(self : UsersStorage, p : Principal) : ?Nat = self.usersLookup.get(p);
  public func get(self : UsersStorage, p : Principal) : ?User.User = switch (self.usersLookup.get(p)) {
    case (?idx) ?atIndex(self, idx);
    case (null) null;
  };

  public func getOrCreate(self : UsersStorage, p : Principal) : User.User = switch (get(self, p)) {
    case (?info) info;
    case (null) {
      let data = User.new();
      let index = self.usersList.size();
      self.usersList.add(data);
      self.usersLookup.add(p, index);
      self.participantsArchive.add(p, { lastOrderPlacement = 0 : Nat64 });
      self.participantsArchiveSize += 1;
      data;
    };
  };

};
