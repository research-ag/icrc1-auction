import Array "mo:base/Array";
import AssocList "mo:base/AssocList";
import List "mo:base/List";
import Nat "mo:base/Nat";

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

    public func deleteIfEmpty(userInfo : T.UserInfo, assetId : T.AssetId) : Bool {
      let (upd, ?acc) = AssocList.replace<T.AssetId, T.Account>(userInfo.credits, assetId, Nat.equal, null) else return false;
      if (isAccountEmpty(acc)) {
        accountsAmount -= 1;
        userInfo.credits := upd;
        return true;
      };
      false;
    };

    public func balance(userInfo : T.UserInfo, assetId : T.AssetId) : Nat = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountBalance(acc);
      case (null) 0;
    };

    public func info(userInfo : T.UserInfo, assetId : T.AssetId) : CreditInfo = switch (getAccount(userInfo, assetId)) {
      case (?acc) accountInfo(acc);
      case (null) ({ total = 0; locked = 0; available = 0 });
    };

    public func infoAll(userInfo : T.UserInfo) : [(T.AssetId, CreditInfo)] {
      let length = List.size(userInfo.credits);
      var list = userInfo.credits;
      Array.tabulate<(T.AssetId, CreditInfo)>(
        length,
        func(i) {
          let popped = List.pop(list);
          list := popped.1;
          switch (popped.0) {
            case null { loop { assert false } };
            case (?x) (x.0, accountInfo(x.1));
          };
        },
      );
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
