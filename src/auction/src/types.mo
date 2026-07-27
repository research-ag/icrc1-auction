import List "mo:core/List";
import Map "mo:core/Map";

import CircularBuffer "./models/circular_buffer";
import PriorityQueue "./models/priority_queue";

module {

  public type UserId = Nat;
  public type AssetId = Nat;
  public type OrderId = Nat;

  public type AuctionNew = {
    quoteAssetId : AssetId;
    settings : AuctionSettings;

    users : List.List<User>;
  };

  public type AuctionSettings = {
    volumeStepLog10 : Nat; // 3 will make volume step 1000 (denominated in quote token)
    minVolumeSteps : Nat; // == minVolume / volumeStep
    priceMaxDigits : Nat;
  };

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type OrderBookType = { #delayed; #immediate };

  public type Order = {
    userPrincipal : Principal;
    userId : UserId;
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

  public type Asset = {
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

  public type CreditInfo = {
    total : Nat;
    available : Nat;
    locked : Nat;
  };

  public type UserSettings = {
    var pushNotificationsEnabled : Bool;
  };

  public type User = {
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

  public type UsersStorage = {
    // TODO remove var from list and maps
    var usersList : List.List<User>;
    var usersLookup : Map.Map<Principal, Nat>;
    var participantsArchive : Map.Map<Principal, { lastOrderPlacement : Nat64 }>;

    var participantsArchiveSize : Nat;

    // TODO move this to a different place
    var quoteSurplus : Nat;
  };

  public type AssetsStorage = {
    // TODO remove var-s here
    var assets : List.List<Asset>;
    var history : {
      immediate : CircularBuffer.CircularBuffer<PriceHistoryItem>;
      delayed : List.List<PriceHistoryItem>;
    };
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type PushNotification = {
    #orderFulfilled : {
      assetId : AssetId;
      kind : { #ask; #bid };
      price : Float;
      baseVolume : Nat;
      quoteVolume : Nat;
      isPartial : Bool;
    };
  };

  // stable data types
  public type StableDataV5 = {
    assets : AssetsStorage;
    orders : { globalCounter : Nat };
    sessions : {
      counter : Nat;
      history : {
        immediate : CircularBuffer.CircularBuffer<PriceHistoryItem>;
        delayed : List.List<PriceHistoryItem>;
      };
    };
    users : UsersStorage;
  };

};
