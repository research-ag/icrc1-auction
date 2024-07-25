import AssocList "mo:base/AssocList";
import Nat "mo:base/Nat";

import T "./types";

module {

  public type Account = {
    // balance of user account
    var credit : Nat;
    // user's credit, placed as bid or ask
    var lockedCredit : Nat;
  };

  public type CreditInfo = {
    total : Nat;
    available : Nat;
    locked : Nat;
  };

  type UserInfo = {
    var credits : AssocList.AssocList<T.AssetId, Account>;
  };

  // TODO try to make these private and implement all functionality which uses it here in this module. Account should be internal type
  public func getAccount(userInfo : UserInfo, assetId : T.AssetId) : ?Account = AssocList.find<T.AssetId, Account>(userInfo.credits, assetId, Nat.equal);

  public func getOrCreateAccount(userInfo : UserInfo, assetId : T.AssetId) : (Account, Bool) {
    switch (getAccount(userInfo, assetId)) {
      case (?acc) (acc, false);
      case (null) {
        let acc = { var credit = 0; var lockedCredit = 0 };
        AssocList.replace<T.AssetId, Account>(userInfo.credits, assetId, Nat.equal, ?acc) |> (userInfo.credits := _.0);
        (acc, true);
      };
    };
  };

  public func availableBalance(account : Account) : Nat = account.credit - account.lockedCredit;
  public func info(account : Account) : CreditInfo = {
    total = account.credit;
    locked = account.lockedCredit;
    available = account.credit - account.lockedCredit;
  };

  public func appendCredit(account : Account, amount : Nat) : Nat {
    account.credit += amount;
    account.credit - account.lockedCredit;
  };

  public func deductCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (account.credit < amount + account.lockedCredit) return (false, availableBalance(account));
    account.credit -= amount;
    (true, availableBalance(account));
  };

  public func unlockCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (amount > account.lockedCredit) {
      return (false, availableBalance(account));
    };
    account.lockedCredit -= amount;
    (true, availableBalance(account));
  };

  public func lockCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (amount + account.lockedCredit > account.credit) {
      return (false, availableBalance(account));
    };
    account.lockedCredit += amount;
    (true, availableBalance(account));
  };

};
