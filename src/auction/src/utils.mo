import {
  abs;
  intToFloat;
  shiftRight;
  shiftLeft;
  floatCeil;
  floatFloor;
  floatToInt;
} "mo:prim";

module {

  // Multiplies Nat by Float and returns the result as Nat, flooring the float value and overcoming float precision problems
  public func multiplyNatByFloatMin(value : Nat, multiplier : Float) : Nat {
    // the precision problem: intToFloat always rounds up, so we need to shift the volume to the right until it fits into 53 bits, then denominate, then shift back
    var high = shiftRight(value, 53);
    var shift : Nat32 = 0;
    var fixedValue = value;
    while (high != 0) {
      high := shiftRight(high, 1);
      shift += 1;
    };
    if (shift > 0) {
      fixedValue := shiftRight(value, shift);
    };

    var result = multiplier * intToFloat(fixedValue)
    |> floatFloor(_)
    |> abs(floatToInt(_));

    if (shift > 0) {
      result := shiftLeft(result, shift);
    };
    result;
  };

  public func multiplyNatByFloatMax(value : Nat, multiplier : Float) : Nat {
    multiplier * intToFloat(value)
    |> floatCeil(_)
    |> abs(floatToInt(_));
  };

};
