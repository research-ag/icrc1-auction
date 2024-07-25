import AssocList "mo:base/AssocList";
import Nat "mo:base/Nat";

import T "./types";

module {

  // TODO check that fields are not used anywhere. Rename field and ensure that to fix only this file has to be edited
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

  public func balance(userInfo : UserInfo, assetId : T.AssetId) : Nat = switch (getAccount(userInfo, assetId)) {
    case (?acc) accountBalance(acc);
    case (null) 0;
  };

  public func info(userInfo : UserInfo, assetId : T.AssetId) : CreditInfo = switch (getAccount(userInfo, assetId)) {
    case (?acc) accountInfo(acc);
    case (null) ({ total = 0; locked = 0; available = 0 });
  };

  public func accountBalance(account : Account) : Nat = account.credit - account.lockedCredit;
  public func accountInfo(account : Account) : CreditInfo = {
    total = account.credit;
    locked = account.lockedCredit;
    available = account.credit - account.lockedCredit;
  };

  public func appendCredit(account : Account, amount : Nat) : Nat {
    account.credit += amount;
    account.credit - account.lockedCredit;
  };

  public func deductCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (account.credit < amount + account.lockedCredit) return (false, accountBalance(account));
    account.credit -= amount;
    (true, accountBalance(account));
  };

  public func unlockCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (amount > account.lockedCredit) {
      return (false, accountBalance(account));
    };
    account.lockedCredit -= amount;
    (true, accountBalance(account));
  };

  public func lockCredit(account : Account, amount : Nat) : (Bool, Nat) {
    if (amount + account.lockedCredit > account.credit) {
      return (false, accountBalance(account));
    };
    account.lockedCredit += amount;
    (true, accountBalance(account));
  };

};
