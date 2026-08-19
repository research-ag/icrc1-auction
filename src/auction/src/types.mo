import List "mo:core/List";
import Map "mo:core/Map";
import Int "mo:core/Int";
import Float "mo:core/Float";

import DecimalNat "mo:safe-financial-math/DecimalNat";

import CircularBuffer "./models/circular_buffer";
import PriorityQueue "./models/priority_queue";

module {

  public func priceToDecimal(price : Float) : DecimalNat.DecimalNat = DecimalNat.new(Int.abs(Float.toInt(Float.floor(price * 100_000_000.0))), 8);

  public type UserId = Nat;
  public type AssetId = Nat;
  public type OrderId = Nat;

  public type Auction = {
    quoteAssetId : AssetId;
    settings : AuctionSettings;

    assets : AssetsStorage;
    users : UsersStorage;

    var ordersCounter : Nat;
    var sessionsCounter : Nat;
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
    price : DecimalNat.DecimalNat;
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
    usersList : List.List<User>;
    usersLookup : Map.Map<Principal, Nat>;
    participantsArchive : Map.Map<Principal, { lastOrderPlacement : Nat64 }>;

    var participantsArchiveSize : Nat;

    // TODO move this to a different place
    var quoteSurplus : Nat;
  };

  public type AssetsStorage = {
    assets : List.List<Asset>;
    history : {
      immediate : CircularBuffer.CircularBuffer<PriceHistoryItem>;
      delayed : List.List<PriceHistoryItem>;
    };
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type CancellationAction = {
    #all : ?[AssetId];
    #orders : [{ #ask : OrderId; #bid : OrderId }];
  };

  public type PlaceOrderAction = {
    #ask : (assetId : AssetId, orderBookType : OrderBookType, volume : Nat, price : Float);
    #bid : (assetId : AssetId, orderBookType : OrderBookType, volume : Nat, price : Float);
  };

  public type CancellationResult = (OrderId, assetId : AssetId, orderBookType : OrderBookType, volume : Nat, price : Float);
  public type PlaceOrderResult = (OrderId, { #placed; #executed : [(price : Float, volume : Nat)] });

  public type InternalCancelOrderError = {
    #UnknownOrder;
  };
  public type InternalPlaceOrderError = {
    #ConflictingOrder : ({ #ask; #bid }, ?OrderId);
    #NoCredit;
    #TooLowOrder;
    #UnknownAsset;
    #PriceDigitsOverflow : { maxDigits : Nat };
    #VolumeStepViolated : { baseVolumeStep : Nat };
  };

  public type OrderManagementError = {
    #AccountRevisionMismatch;
    #cancellation : { index : Nat; error : InternalCancelOrderError };
    #placement : { index : Nat; error : InternalPlaceOrderError };
  };

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

};
