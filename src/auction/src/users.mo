import AssocList "mo:base/AssocList";
import List "mo:base/List";
import Nat "mo:base/Nat";
import Prim "mo:prim";
import Principal "mo:base/Principal";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import T "./types";

module {

  public class Users() {

    public var usersAmount : Nat = 0;
    public let users : RBTree.RBTree<Principal, T.UserInfo> = RBTree.RBTree<Principal, T.UserInfo>(Principal.compare);

    public func nUsers() : Nat = usersAmount;
    public func nUsersWithCredits() : Nat {
      var res : Nat = 0;
      for ((_, user) in users.entries()) {
        if (not List.isNil(user.credits)) {
          res += 1;
        };
      };
      res;
    };
    public func nUsersWithActiveOrders() : Nat {
      var res : Nat = 0;
      for ((_, user) in users.entries()) {
        if (not List.isNil(user.asks.map) or not List.isNil(user.bids.map)) {
          res += 1;
        };
      };
      res;
    };

    public var participantsArchiveSize : Nat = 0;
    public let participantsArchive : RBTree.RBTree<Principal, { lastOrderPlacement : Nat64 }> = RBTree.RBTree<Principal, { lastOrderPlacement : Nat64 }>(Principal.compare);

    public func get(p : Principal) : ?T.UserInfo = users.get(p);

    public func getOrCreate(p : Principal) : T.UserInfo = switch (get(p)) {
      case (?info) info;
      case (null) {
        let data : T.UserInfo = {
          asks = { var map = null };
          bids = { var map = null };
          var darkOrderBooks = null;
          var credits = null;
          var accountRevision = 0;
          var loyaltyPoints = 0;
          var depositHistory = Vec.new<T.DepositHistoryItem>();
          var transactionHistory = Vec.new<T.TransactionHistoryItem>();
        };
        let oldValue = users.replace(p, data);
        switch (oldValue) {
          case (?_) Prim.trap("Prevented user data overwrite");
          case (_) {};
        };
        usersAmount += 1;
        participantsArchive.put(p, { lastOrderPlacement = 0 });
        participantsArchiveSize += 1;
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

    public func deleteOrder(user : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
      let orderBook = getOrderBook(user, kind);
      let (updatedList, oldValue) = AssocList.replace(orderBook.map, orderId, Nat.equal, null);
      let ?existingOrder = oldValue else return null;
      orderBook.map := updatedList;
      ?existingOrder;
    };

    public func findDarkOrderBook(user : T.UserInfo, asset : T.AssetId) : ?T.EncryptedOrderBook {
      AssocList.find(user.darkOrderBooks, asset, Nat.equal);
    };

    public func putDarkOrderBook(user : T.UserInfo, asset : T.AssetId, data : ?T.EncryptedOrderBook) : ?T.EncryptedOrderBook {
      let (upd, oldValue) = AssocList.replace(user.darkOrderBooks, asset, Nat.equal, data);
      user.darkOrderBooks := upd;
      oldValue;
    };

  };

};
