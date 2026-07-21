import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";

import List "mo:core/List";
import Map "mo:core/Map";
import PureList "mo:core/pure/List";
import Queue "mo:core/Queue";

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

    public var usersAmount : Nat = 0;
    public let users : Map.Map<Principal, T.UserInfo> = Map.empty<Principal, T.UserInfo>();

    public func nUsers() : Nat = usersAmount;
    public func nUsersWithCredits() : Nat {
      var res : Nat = 0;
      for (user in Map.values(users)) {
        if (not user.credits.isEmpty()) {
          res += 1;
        };
      };
      res;
    };
    public func nUsersWithActiveOrders() : Nat {
      var res : Nat = 0;
      for (user in Map.values(users)) {
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

    public func get(p : Principal) : ?T.UserInfo = Map.get(users, Principal.compare, p);

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
        let oldValue = Map.swap(users, Principal.compare, p, data);
        switch (oldValue) {
          case (?_) Prim.trap("Prevented user data overwrite");
          case (_) {};
        };
        usersAmount += 1;
        Map.add(participantsArchive, Principal.compare, p, { lastOrderPlacement = 0 : Nat64 });
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
