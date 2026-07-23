import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import List "mo:core/List";
import Map "mo:core/Map";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";
import Runtime "mo:core/Runtime";

import T "./types";

module {

  public type PushNotification = {
    #orderFulfilled : {
      assetId : T.AssetId;
      kind : { #ask; #bid };
      price : Float;
      baseVolume : Nat;
      quoteVolume : Nat;
      isPartial : Bool;
    };
  };

  public class Users() {

    public let usersList : List.List<T.UserInfo> = List.empty();
    public let usersLookup : Map.Map<Principal, Nat> = Map.empty<Principal, Nat>();

    public func nUsers() : Nat = usersList.size();
    public func nUsersWithCredits() : Nat {
      var res : Nat = 0;
      for (user in usersList.values()) {
        if (not user.credits.isEmpty()) {
          res += 1;
        };
      };
      res;
    };
    public func nUsersWithActiveOrders() : Nat {
      var res : Nat = 0;
      for (user in usersList.values()) {
        if (not user.asks.map.isEmpty() or not user.bids.map.isEmpty()) {
          res += 1;
        };
      };
      res;
    };

    public var participantsArchiveSize : Nat = 0;
    public let participantsArchive : Map.Map<Principal, { lastOrderPlacement : Nat64 }> = Map.empty<Principal, { lastOrderPlacement : Nat64 }>();

    // This field does not survive upgrades, since we (currently) send them straight away
    public var stagedPushNotifications : Queue.Queue<(user : Principal, notification : PushNotification)> = Queue.empty();

    public func getByIndex(idx : Nat) : ?T.UserInfo = usersList.get(idx);
    public func atIndex(idx : Nat) : T.UserInfo = usersList.at(idx);

    public func getIndex(p : Principal) : ?Nat = usersLookup.get(p);
    public func get(p : Principal) : ?T.UserInfo = switch (usersLookup.get(p)) {
      case (?idx) ?atIndex(idx);
      case (null) null;
    };

    public func getOrCreate(p : Principal) : T.UserInfo = switch (get(p)) {
      case (?info) info;
      case (null) {
        let data : T.UserInfo = {
          asks = { var map = Map.empty() };
          bids = { var map = Map.empty() };
          var darkOrderBooks = Map.empty();
          var credits = Map.empty();
          var accountRevision = 0;
          var loyaltyPoints = 0;
          var depositHistory = List.empty<T.DepositHistoryItem>();
          var transactionHistory = List.empty<T.TransactionHistoryItem>();
          userSettings = {
            var pushNotificationsEnabled = false;
          };
        };
        let index = usersList.size();
        usersList.add(data);
        usersLookup.add(p, index);
        participantsArchive.add(p, { lastOrderPlacement = 0 : Nat64 });
        participantsArchiveSize += 1;
        data;
      };
    };

    public func getOrderBook(user : T.UserInfo, kind : { #ask; #bid }) : T.UserOrderBook = switch (kind) {
      case (#ask) user.asks;
      case (#bid) user.bids;
    };

    public func findOrder(userInfo : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
      getOrderBook(userInfo, kind).map.get(orderId);
    };

    public func putOrder(user : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId, order : T.Order) {
      getOrderBook(user, kind).map.add(orderId, order);
    };

    public func deleteOrder(user : T.UserInfo, kind : { #ask; #bid }, orderId : T.OrderId) : ?T.Order {
      getOrderBook(user, kind).map.take(orderId);
    };

    public func findDarkOrderBook(user : T.UserInfo, asset : T.AssetId) : ?T.EncryptedOrderBook {
      user.darkOrderBooks.get(asset);
    };

    public func putDarkOrderBook(user : T.UserInfo, asset : T.AssetId, data : ?T.EncryptedOrderBook) : ?T.EncryptedOrderBook {
      switch (data) {
        case (?d) user.darkOrderBooks.swap(asset, d);
        case (null) user.darkOrderBooks.take(asset);
      };
    };

  };

};
