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
    var surplus : Nat;
  };

  public type UserInfo = {
    asks : UserOrderBook;
    bids : UserOrderBook;
    var credits : AssocList.AssocList<AssetId, Account>;
    var history : List.List<TransactionHistoryItem>;
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  // stable data types
  public type StableAssetInfoV3 = {
    lastRate : Float;
    lastProcessingInstructions : Nat;
    surplus : Nat;
  };
  public type StableDataV3 = {
    counters : (sessions : Nat, orders : Nat, users : Nat, accounts : Nat);
    assets : Vec.Vector<StableAssetInfoV3>;
    history : List.List<PriceHistoryItem>;
    users : RBTree.Tree<Principal, StableUserInfoV2>;
  };

  public type StableOrderDataV2 = {
    user : Principal;
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };
  public type StableAssetInfoV2 = {
    lastRate : Float;
    lastProcessingInstructions : Nat;
  };
  public type StableUserInfoV2 = {
    asks : UserOrderBook_<StableOrderDataV2>;
    bids : UserOrderBook_<StableOrderDataV2>;
    credits : AssocList.AssocList<AssetId, Account>;
    history : List.List<TransactionHistoryItem>;
  };
  public type StableDataV2 = {
    counters : (sessions : Nat, orders : Nat, users : Nat, accounts : Nat);
    assets : Vec.Vector<StableAssetInfoV2>;
    history : List.List<PriceHistoryItem>;
    users : RBTree.Tree<Principal, StableUserInfoV2>;
  };

  // old stable data types
  public type StableOrderV1 = {
    user : Principal;
    userInfoRef : StableUserInfoV1;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };
  public type StableUserInfoV1 = {
    var currentAsks : AssocList.AssocList<OrderId, StableOrderV1>;
    var currentBids : AssocList.AssocList<OrderId, StableOrderV1>;
    var credits : AssocList.AssocList<AssetId, Account>;
    var history : List.List<TransactionHistoryItem>;
  };
  public type StableAssetInfoV1 = {
    asks : PriorityQueue.PriorityQueue<(OrderId, StableOrderV1)>;
    bids : PriorityQueue.PriorityQueue<(OrderId, StableOrderV1)>;
    lastRate : Float;
  };
  public type StableDataV1 = {
    counters : (sessions : Nat, orders : Nat);
    assets : Vec.Vector<StableAssetInfoV1>;
    users : RBTree.Tree<Principal, StableUserInfoV1>;
    history : List.List<PriceHistoryItem>;
    stats : {
      usersAmount : Nat;
      accountsAmount : Nat;
      assets : Vec.Vector<{ bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }>;
    };
  };

};
