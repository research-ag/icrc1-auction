import AssocList "mo:base/AssocList";
import Nat "mo:base/Nat";
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
          asks = { var map = null };
          bids = { var map = null };
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

    public func getOrderBook(user : T.UserInfo, kind : { #ask; #bid }) : T.UserOrderBook = switch (kind) {
      case (#ask) user.asks;
      case (#bid) user.bids;
    };

    public func findOrder(userInfo : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
      AssocList.find(getOrderBook(userInfo, kind).map, orderId, Nat.equal);
    };

    public func putOrder(user : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
      let orderBook = getOrderBook(user, kind);
      AssocList.replace<T.OrderId, T.Order>(orderBook.map, orderId, Nat.equal, ?order) |> (orderBook.map := _.0);
    };

    public func popOrder(user : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
      let orderBook = getOrderBook(user, kind);
      let (updatedList, oldValue) = AssocList.replace(orderBook.map, orderId, Nat.equal, null);
      let ?existingOrder = oldValue else return null;
      orderBook.map := updatedList;
      ?existingOrder;
    };

  };

};
