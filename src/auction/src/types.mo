import AssocList "mo:base/AssocList";
import List "mo:base/List";
import RBTree "mo:base/RBTree";

import Vec "mo:vector";

import PriorityQueue "./priority_queue";

module {

  public type AssetId = Nat;
  public type OrderId = Nat;

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type OrderType = { #delayed; #immediate };

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    orderType : OrderType;
    price : Float;
    var volume : Nat;
  };

  public type AssetOrderBook = {
    kind : { #ask; #bid };
    var queue : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var size : Nat;
    var totalVolume : Nat;
  };

  public type UserOrderBook_<O> = {
    var map : AssocList.AssocList<OrderId, O>;
  };
  public type UserOrderBook = UserOrderBook_<Order>;

  public type AssetInfo = {
    asks : {
      immediate : AssetOrderBook;
      delayed : AssetOrderBook;
    };
    bids : {
      immediate : AssetOrderBook;
      delayed : AssetOrderBook;
    };
    var lastRate : Float;
    var lastProcessingInstructions : Nat;
    var totalExecutedVolumeBase : Nat;
    var totalExecutedVolumeQuote : Nat;
    var totalExecutedOrders : Nat;
    var sessionsCounter : Nat;
  };

  public type UserInfo = {
    asks : UserOrderBook;
    bids : UserOrderBook;
    var credits : AssocList.AssocList<AssetId, Account>;
    var loyaltyPoints : Nat;
    var depositHistory : Vec.Vector<DepositHistoryItem>;
    var transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  // stable data types
  public type StableDataV9 = StableDataV5_6_7<StableAssetInfoV3, StableUserInfoV7, { globalCounter : Nat }, { surplus : Nat }>;

  // old stable data types
  public type StableDataV8 = StableDataV5_6_7<StableAssetInfoV3, StableUserInfoV6, { globalCounter : Nat }, { surplus : Nat }>;
  public type StableDataV7 = StableDataV5_6_7<StableAssetInfoV3, StableUserInfoV5, { globalCounter : Nat }, { surplus : Nat }>;
  public type StableDataV6 = StableDataV5_6_7<StableAssetInfoV2, StableUserInfoV4, { globalCounter : Nat; fulfilledCounter : Nat }, { totalProcessedVolume : Nat; surplus : Nat }>;
  public type StableDataV5 = StableDataV5_6_7<StableAssetInfoV2, StableUserInfoV3, { globalCounter : Nat; fulfilledCounter : Nat }, { totalProcessedVolume : Nat; surplus : Nat }>;
  public type StableDataV5_6_7<SAI, SUI, O, Q> = {
    assets : Vec.Vector<SAI>;
    orders : O;
    quoteToken : Q;
    sessions : {
      counter : Nat;
      history : Vec.Vector<PriceHistoryItem>;
    };
    users : {
      registry : {
        tree : RBTree.Tree<Principal, SUI>;
        size : Nat;
      };
      participantsArchive : {
        tree : RBTree.Tree<Principal, { lastOrderPlacement : Nat64 }>;
        size : Nat;
      };
      accountsAmount : Nat;
    };
  };
  public type StableDataV4 = {
    assets : Vec.Vector<StableAssetInfoV2>;
    orders : {
      globalCounter : Nat;
      fulfilledCounter : Nat;
    };
    quoteToken : {
      totalProcessedVolume : Nat;
      surplus : Nat;
    };
    sessions : {
      counter : Nat;
      history : List.List<PriceHistoryItem>;
    };
    users : {
      registry : {
        tree : RBTree.Tree<Principal, StableUserInfoV2>;
        size : Nat;
      };
      participantsArchive : {
        tree : RBTree.Tree<Principal, { lastOrderPlacement : Nat64 }>;
        size : Nat;
      };
      accountsAmount : Nat;
    };
  };

  public type StableDataV3 = {
    counters : (sessions : Nat, orders : Nat, users : Nat, accounts : Nat);
    assets : Vec.Vector<StableAssetInfoV2>;
    history : List.List<PriceHistoryItem>;
    users : RBTree.Tree<Principal, StableUserInfoV2>;
    quoteSurplus : Nat;
  };

  public type StableOrderDataV3 = {
    user : Principal;
    assetId : AssetId;
    orderType : OrderType;
    price : Float;
    volume : Nat;
  };
  public type StableOrderDataV2 = {
    user : Principal;
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };
  public type StableAssetInfoV3 = {
    lastRate : Float;
    lastProcessingInstructions : Nat;
    totalExecutedVolumeBase : Nat;
    totalExecutedVolumeQuote : Nat;
    totalExecutedOrders : Nat;
  };
  public type StableAssetInfoV2 = {
    lastRate : Float;
    lastProcessingInstructions : Nat;
  };
  public type StableUserInfoV7 = {
    asks : UserOrderBook_<StableOrderDataV3>;
    bids : UserOrderBook_<StableOrderDataV3>;
    credits : AssocList.AssocList<AssetId, Account>;
    loyaltyPoints : Nat;
    depositHistory : Vec.Vector<DepositHistoryItem>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableUserInfoV6 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    loyaltyPoints : Nat;
    depositHistory : Vec.Vector<DepositHistoryItem>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableUserInfoV5 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    loyaltyPoints : Nat;
    depositHistory : Vec.Vector<(timestamp : Nat64, kind : { #deposit; #withdrawal; #withdrawalRollback }, assetId : AssetId, volume : Nat)>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableUserInfoV4 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    depositHistory : Vec.Vector<(timestamp : Nat64, kind : { #deposit; #withdrawal; #withdrawalRollback }, assetId : AssetId, volume : Nat)>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableUserInfoV3 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    history : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableUserInfoV2 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    history : List.List<TransactionHistoryItem>;
  };

};
