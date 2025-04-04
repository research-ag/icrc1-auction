import AssocList "mo:base/AssocList";
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

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };

  type AssetOrderBook_<O> = {
    var queue : PriorityQueue.PriorityQueue<(OrderId, O)>;
    var size : Nat;
    var totalVolume : Nat;
  };
  public type AssetOrderBook = AssetOrderBook_<Order>;

  public type UserOrderBook_<O> = {
    var map : AssocList.AssocList<OrderId, O>;
  };
  public type UserOrderBook = UserOrderBook_<Order>;

  public type AssetInfo = {
    asks : AssetOrderBook;
    bids : AssetOrderBook;
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
  public type DepositHistoryItem = (timestamp : Nat64, kind : { #deposit : ?Blob; #withdrawal : ?Blob }, assetId : AssetId, volume : Nat);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  // stable data types
  public type StableDataV2 = {
    assets : Vec.Vector<StableAssetInfoV1>;
    orders : { globalCounter : Nat };
    quoteToken : { surplus : Nat };
    sessions : {
      counter : Nat;
      history : Vec.Vector<PriceHistoryItem>;
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

  public type StableAssetInfoV1 = {
    lastRate : Float;
    lastProcessingInstructions : Nat;
    totalExecutedVolumeBase : Nat;
    totalExecutedVolumeQuote : Nat;
    totalExecutedOrders : Nat;
  };
  public type StableUserInfoV2 = {
    asks : UserOrderBook_<StableOrderDataV1>;
    bids : UserOrderBook_<StableOrderDataV1>;
    credits : AssocList.AssocList<AssetId, Account>;
    loyaltyPoints : Nat;
    depositHistory : Vec.Vector<DepositHistoryItem>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };
  public type StableOrderDataV1 = {
    user : Principal;
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };

  // old stable data types
  public type StableDataV1 = {
    assets : Vec.Vector<StableAssetInfoV1>;
    orders : { globalCounter : Nat };
    quoteToken : { surplus : Nat };
    sessions : {
      counter : Nat;
      history : Vec.Vector<PriceHistoryItem>;
    };
    users : {
      registry : {
        tree : RBTree.Tree<Principal, StableUserInfoV1>;
        size : Nat;
      };
      participantsArchive : {
        tree : RBTree.Tree<Principal, { lastOrderPlacement : Nat64 }>;
        size : Nat;
      };
      accountsAmount : Nat;
    };
  };
  public type StableUserInfoV1 = {
    asks : UserOrderBook_<StableOrderDataV1>;
    bids : UserOrderBook_<StableOrderDataV1>;
    credits : AssocList.AssocList<AssetId, Account>;
    loyaltyPoints : Nat;
    depositHistory : Vec.Vector<(timestamp : Nat64, kind : { #deposit; #withdrawal }, assetId : AssetId, volume : Nat)>;
    transactionHistory : Vec.Vector<TransactionHistoryItem>;
  };

};
