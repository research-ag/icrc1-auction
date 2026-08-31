import T "./types";

module {

  public type Account = T.Account;

  public func isEmpty(self : T.Account) : Bool = self.credit == 0 and self.lockedCredit == 0;

  public func balance(self : T.Account) : Nat = self.credit - self.lockedCredit;

  public func creditInfo(self : T.Account) : T.CreditInfo = {
    total = self.credit;
    locked = self.lockedCredit;
    available = self.credit - self.lockedCredit;
  };

  public func appendCredit(self : T.Account, amount : Nat) : Nat {
    self.credit += amount;
    self.credit - self.lockedCredit;
  };

  public func deductCredit(self : T.Account, amount : Nat) : (Bool, Nat) {
    if (self.credit < amount + self.lockedCredit) return (false, balance(self));
    self.credit -= amount;
    (true, balance(self));
  };

  public func unlockCredit(self : T.Account, amount : Nat) : (Bool, Nat) {
    if (amount > self.lockedCredit) {
      return (false, balance(self));
    };
    self.lockedCredit -= amount;
    (true, balance(self));
  };

  public func lockCredit(self : T.Account, amount : Nat) : (Bool, Nat) {
    if (amount + self.lockedCredit > self.credit) {
      return (false, balance(self));
    };
    self.lockedCredit += amount;
    (true, balance(self));
  };

};
