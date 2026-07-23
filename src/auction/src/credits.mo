import Array "mo:core/Array";
import Iter "mo:core/Iter";
import PureList "mo:core/pure/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";

import T "./types";

module {

  public type CreditInfo = {
    total : Nat;
    available : Nat;
    locked : Nat;
  };

  public class Credits() {

    public var accountsAmount : Nat = 0;

    public var quoteSurplus : Nat = 0;

    public func nAccounts() : Nat = accountsAmount;

    public func getAccount(userInfo : T.User, assetId : T.AssetId) : ?T.Account = userInfo.credits.get(assetId);

    public func getOrCreate(userInfo : T.User, assetId : T.AssetId) : T.Account {
      switch (getAccount(userInfo, assetId)) {
        case (?acc) acc;
        case (null) {
          let acc = { var credit = 0; var lockedCredit = 0 };
          userInfo.credits.add(assetId, acc);
          accountsAmount += 1;
          acc;
        };
      };
    };

    public func deleteIfEmpty(userInfo : T.User, assetId : T.AssetId) : Bool {
      let ?acc = userInfo.credits.get(assetId) else return false;
      if (isAccountEmpty(acc)) {
        accountsAmount -= 1;
        userInfo.credits.remove(assetId);
        return true;
      };
      false;
    };

    public func balance(userInfo : T.User, assetId : T.AssetId) : Nat = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountBalance(acc);
      case (null) 0;
    };

    public func info(userInfo : T.User, assetId : T.AssetId) : CreditInfo = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountInfo(acc);
      case (null) ({ total = 0; locked = 0; available = 0 });
    };

    public func infoAll(userInfo : T.User) : [(T.AssetId, CreditInfo)] {
      userInfo.credits.entries().map(func(aid, ci) = (aid, accountInfo(ci))).toArray();
    };

    public func accountBalance(account : T.Account) : Nat = account.credit - account.lockedCredit;

    public func accountInfo(account : T.Account) : CreditInfo = {
      total = account.credit;
      locked = account.lockedCredit;
      available = account.credit - account.lockedCredit;
    };

    public func isAccountEmpty(account : T.Account) : Bool = account.credit == 0 and account.lockedCredit == 0;

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
