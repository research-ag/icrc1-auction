import AssocList "mo:base/AssocList";
import Nat "mo:base/Nat";

import T "./types";

module {

  public type CreditInfo = {
    total : Nat;
    available : Nat;
    locked : Nat;
  };

  public class CreditsRepo() {
    public var accountsAmount : Nat = 0;

    public func getAccount(userInfo : T.UserInfo, assetId : T.AssetId) : ?T.Account = AssocList.find<T.AssetId, T.Account>(userInfo.credits, assetId, Nat.equal);

    public func getOrCreate(userInfo : T.UserInfo, assetId : T.AssetId) : T.Account {
      switch (getAccount(userInfo, assetId)) {
        case (?acc) acc;
        case (null) {
          let acc = { var credit = 0; var lockedCredit = 0 };
          AssocList.replace<T.AssetId, T.Account>(userInfo.credits, assetId, Nat.equal, ?acc) |> (userInfo.credits := _.0);
          accountsAmount += 1;
          acc;
        };
      };
    };

    public func balance(userInfo : T.UserInfo, assetId : T.AssetId) : Nat = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountBalance(acc);
      case (null) 0;
    };

    public func info(userInfo : T.UserInfo, assetId : T.AssetId) : CreditInfo = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountInfo(acc);
      case (null) ({ total = 0; locked = 0; available = 0 });
    };

    public func accountBalance(account : T.Account) : Nat = account.credit - account.lockedCredit;
    public func accountInfo(account : T.Account) : CreditInfo = {
      total = account.credit;
      locked = account.lockedCredit;
      available = account.credit - account.lockedCredit;
    };

    public func appendCredit(account : T.Account, amount : Nat) : Nat {
      account.credit += amount;
      account.credit - account.lockedCredit;
    };

    public func deductCredit(account : T.Account, amount : Nat) : (Bool, Nat) {
      if (account.credit < amount + account.lockedCredit) return (false, accountBalance(account));
      account.credit -= amount;
      (true, accountBalance(account));
    };

    public func unlockCredit(account : T.Account, amount : Nat) : (Bool, Nat) {
      if (amount > account.lockedCredit) {
        return (false, accountBalance(account));
      };
      account.lockedCredit -= amount;
      (true, accountBalance(account));
    };

    public func lockCredit(account : T.Account, amount : Nat) : (Bool, Nat) {
      if (amount + account.lockedCredit > account.credit) {
        return (false, accountBalance(account));
      };
      account.lockedCredit += amount;
      (true, accountBalance(account));
    };
  };

};
