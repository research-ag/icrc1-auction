import Float "mo:core/Float";

module FloatUtils {
  public func scaleFloat(value : Float, decimals : Int) : Float {
    if (decimals == 0) {
      value;
    } else if (decimals > 0) {
      value * Float.pow(10.0, Float.fromInt(decimals));
    } else {
      value / Float.pow(10.0, Float.fromInt(-decimals));
    };
  };
};
