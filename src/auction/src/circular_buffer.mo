import VarArray "mo:core/VarArray";
import Nat "mo:core/Nat";

module {

  public class CircularBuffer<T>(capacity : Nat) {
    var buffer = VarArray.repeat<?T>(null, capacity);
    var head = 0;
    var size = 0;
    var totalPushes = 0;

    public func push(item : T) {
      buffer[head] := ?item;
      head := (head + 1) % capacity;
      if (size < capacity) {
        size += 1;
      };
      totalPushes += 1;
    };

    public func get(index : Nat) : ?T {
      if (index >= capacity) return null;
      buffer[index];
    };

    public func available() : (Nat, Nat) {
      if (size == 0) return (0, 0);
      if (size < capacity) {
        return (0, head);
      } else {
        return (0, capacity);
      };
    };

    public func pushesAmount() : Nat {
      totalPushes;
    };

    public func share() : ([var ?T], Nat, Nat) {
      (buffer, head, size);
    };

    public func unshare(data : ([var ?T], Nat, Nat)) {
      buffer := data.0;
      head := data.1;
      size := data.2;
    };
  };

};
