import Float "mo:core/Float";

module FloatUtils {

  public func round(x : Float) : Float {
    if (x >= 0) {
      Float.floor(x + 0.5);
    } else {
      Float.ceil(x - 0.5);
    };
  };

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
