import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Nat64 "mo:core/Nat64";
import Region "mo:core/Region";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Prim "mo:prim";
import VarArray "mo:core/VarArray";

module CircularBuffer {

  public type CircularBuffer<T> = {
    capacity : Nat;
    var array : [var ?T];
    var last : Nat;
    var pushes : Nat;
  };

  public func new<T>(capacity : Nat) : CircularBuffer<T> {
    assert capacity != 0;
    {
      capacity;
      var array = VarArray.repeat(null, capacity);
      var last = 0;
      var pushes = 0;
    };
  };

  /// Number of items that were ever pushed to the buffer
  public func pushesAmount<T>(self : CircularBuffer<T>) : Nat = self.pushes;

  /// Insert value into the buffer
  public func push<T>(self : CircularBuffer<T>, item : T) {
    self.array[self.last] := ?item;
    self.pushes += 1;
    self.last += 1;
    if (self.last == self.capacity) self.last := 0;
  };

  /// Return interval `[start, end)` of indices of elements available.
  public func available<T>(self : CircularBuffer<T>) : (Nat, Nat) {
    (if (self.pushes <= self.capacity) 0 else self.pushes - self.capacity, self.pushes);
  };

  /// Returns single element added with number `index` or null if element is not available or index out of bounds.
  public func get<T>(self : CircularBuffer<T>, index : Nat) : ?T {
    let (l, r) = available(self);
    if (l <= index and index < r) { self.array[index % self.capacity] } else { null };
  };

  /// Return iterator to values added with numbers in interval `[from; to)`.
  /// `from` should be not more then `to`. Both should be not more then `pushes`.
  public func slice<T>(self : CircularBuffer<T>, from : Nat, to : Nat) : Iter.Iter<T> {
    assert from <= to;
    let interval = available(self);
    assert interval.0 <= from and from <= interval.1 and interval.0 <= to and to <= interval.1;
    let count : Int = to - from;
    object {
      var start = from % self.capacity;
      var i = 0;
      public func next() : ?T {
        if (i == count) return null;
        let ret = self.array[start];
        start += 1;
        if (start == self.capacity) start := 0;
        i += 1;
        ret;
      };
    };
  };

};
