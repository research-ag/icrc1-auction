import List "mo:core/List";
import Map "mo:core/Map";

import CircularBuffer "./models/circular_buffer";
import PriorityQueue "./models/priority_queue";

module {

  public type AssetId = Nat;
  public type OrderId = Nat;

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type OrderBookType = { #delayed; #immediate };

  public type Order = {
    user : Principal;
    userInfoIdx : Nat;
    assetId : AssetId;
    orderBookType : OrderBookType;
    price : Float;
    var volume : Nat;
  };

  // first blob is user-encrypted data, which only user can decrypt, second is the IBE-encrypted data
  public type EncryptedOrderBook = (Blob, Blob);

  public type DecryptedOrderData = {
    kind : { #ask; #bid };
    price : Float;
    volume : Nat;
  };

  public type AssetOrderBook = {
    kind : { #ask; #bid };
    var queue : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var size : Nat;
    var totalVolume : Nat;
  };

  public type UserOrderBook = {
    var map : Map.Map<OrderId, Order>;
  };

  public type AssetInfo = {
    asks : {
      immediate : AssetOrderBook;
      delayed : AssetOrderBook;
    };
    bids : {
      immediate : AssetOrderBook;
      delayed : AssetOrderBook;
    };
    darkOrderBooks : {
      var encrypted : Map.Map<Principal, EncryptedOrderBook>;
      // set right before auction execution
      var decrypted : ?[(Principal, [DecryptedOrderData])];
    };
    var lastRate : Float;
    var lastImmediateRate : Float;
    var immediateExecutionsCounter : Nat;
    var lastProcessingInstructions : Nat;
    var totalExecutedVolumeBase : Nat;
    var totalExecutedVolumeQuote : Nat;
    var totalExecutedOrders : Nat;
    var sessionsCounter : Nat;
  };

  public type UserSettings = {
    var pushNotificationsEnabled : Bool;
  };

  public type UserInfo = {
    asks : UserOrderBook;
    bids : UserOrderBook;
    var darkOrderBooks : Map.Map<AssetId, EncryptedOrderBook>;
    var credits : Map.Map<AssetId, Account>;
    var accountRevision : Nat;
    var loyaltyPoints : Nat;
    var depositHistory : List.List<DepositHistoryItem>;
    var transactionHistory : List.List<TransactionHistoryItem>;
    userSettings : UserSettings;
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  // stable data types
  public type StableDataV5 = {
    assets : List.List<StableAssetInfoV3>;
    orders : { globalCounter : Nat };
    quoteToken : { surplus : Nat };
    sessions : {
      counter : Nat;
      history : {
        immediate : CircularBuffer.CircularBuffer<PriceHistoryItem>;
        delayed : List.List<PriceHistoryItem>;
      };
    };
    users : {
      registry : {
        entries : [(Principal, StableUserInfoV4)];
        size : Nat;
      };
      participantsArchive : {
        entries : [(Principal, { lastOrderPlacement : Nat64 })];
        size : Nat;
      };
      accountsAmount : Nat;
    };
  };
  public type StableUserInfoV4 = {
    asks : {
      var map : Map.Map<OrderId, Order>;
    };
    bids : {
      var map : Map.Map<OrderId, Order>;
    };
    darkOrderBooks : Map.Map<AssetId, EncryptedOrderBook>;
    credits : Map.Map<AssetId, Account>;
    accountRevision : Nat;
    loyaltyPoints : Nat;
    depositHistory : List.List<DepositHistoryItem>;
    transactionHistory : List.List<TransactionHistoryItem>;
    userSettings : { pushNotificationsEnabled : Bool };
  };

  public type StableAssetInfoV3 = {
    lastRate : Float;
    lastImmediateRate : Float;
    immediateExecutionsCounter : Nat;
    lastProcessingInstructions : Nat;
    totalExecutedVolumeBase : Nat;
    totalExecutedVolumeQuote : Nat;
    totalExecutedOrders : Nat;
  };

};
