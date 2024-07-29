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

  public type AssetOrderBook = {
    var queue : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    var amount : Nat;
    var totalVolume : Nat;
  };

  public type AssetInfo = {
    asks : AssetOrderBook;
    bids : AssetOrderBook;
    var lastRate : Float;
    var lastProcessingInstructions : Nat;
  };

  public type StableAssetInfo = {
    asks : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    bids : PriorityQueue.PriorityQueue<(OrderId, Order)>;
    lastRate : Float;
  };

  public type UserInfo = {
    var currentAsks : AssocList.AssocList<OrderId, Order>;
    var currentBids : AssocList.AssocList<OrderId, Order>;
    var credits : AssocList.AssocList<AssetId, Account>;
    var history : List.List<TransactionHistoryItem>;
  };

  public type Order = {
    user : Principal;
    userInfoRef : UserInfo;
    assetId : AssetId;
    price : Float;
    var volume : Nat;
  };

  public type SharedOrder = {
    assetId : AssetId;
    price : Float;
    volume : Nat;
  };

  public type PriceHistoryItem = (timestamp : Nat64, sessionNumber : Nat, assetId : AssetId, volume : Nat, price : Float);
  public type TransactionHistoryItem = (timestamp : Nat64, sessionNumber : Nat, kind : { #ask; #bid }, assetId : AssetId, volume : Nat, price : Float);

  public type StableDataV1 = {
    counters : (sessions : Nat, orders : Nat);
    assets : Vec.Vector<StableAssetInfo>;
    users : RBTree.Tree<Principal, UserInfo>;
    history : List.List<PriceHistoryItem>;
    stats : {
      usersAmount : Nat;
      accountsAmount : Nat;
      assets : Vec.Vector<{ bidsAmount : Nat; totalBidVolume : Nat; asksAmount : Nat; totalAskVolume : Nat; lastProcessingInstructions : Nat }>;
    };
  };

};
