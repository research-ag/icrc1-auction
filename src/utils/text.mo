import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Text "mo:core/Text";

module TextUtils {

  func stripLeadingZeros(x : Text) : Text {
    if (x == "") return x;
    let chars = Text.toArray(x);
    var start : Nat = 0;
    while (start < chars.size() and chars[start] == '0') { start += 1 };
    if (start >= chars.size()) return "";
    Text.fromArray(Array.tabulate<Char>(chars.size() - start, func(i) = chars[start + i]));
  };

  func trimTrailingZeros(x : Text) : Text {
    if (x == "") return x;
    let chars = Text.toArray(x);
    var end : Int = chars.size() - 1;
    label z while (end >= 0 and chars[Int.abs(end)] == '0') { end -= 1 };
    if (end < 0) return "";
    if (chars[Int.abs(end)] == '.') { end -= 1 };
    if (end < 0) return "";
    Text.fromArray(Array.tabulate<Char>(Int.abs(end) + 1, func(i) = chars[i]));
  };

  public func natWithDecimalsToText(value : Nat, decimals : Nat) : Text {
    let s = Nat.toText(value);
    if (decimals == 0) return s;
    let len = s.size();
    if (len == 0) return "0";
    if (len <= decimals) {
      let frac = Iter.concat(
        Iter.repeat<Char>('0', decimals - len),
        Text.toIter(s),
      )
      |> Text.fromIter(_)
      |> trimTrailingZeros(_);
      if (frac == "") return "0";
      return "0." # frac;
    } else {
      let intLen = Int.abs(len - decimals);
      let intPart = Text.toIter(s) |> Iter.take(_, intLen) |> Text.fromIter(_);
      let fracPartRaw = Text.toIter(s) |> Iter.drop(_, intLen) |> Iter.take(_, decimals) |> Text.fromIter(_);
      let intNoLead = stripLeadingZeros(intPart);
      let fracTrim = trimTrailingZeros(fracPartRaw);
      let intRes = if (intNoLead == "") "0" else intNoLead;
      if (fracTrim == "") return intRes;
      intRes # "." # fracTrim;
    };
  };

  // renders float with rule "show 5 most significant digits"
  public func floatToSig5(f : Float) : Text {
    if (f == 0.0) return "0";
    let absF = Float.abs(f);
    let rounded = if (absF >= 10000.0) {
      Float.nearest(f);
    } else {
      let exp = Float.floor(Float.log(absF) / Float.log(10));
      let scale = Float.pow(10, 4.0 - exp);
      Float.nearest(f * scale) / scale;
    };
    let txt = Float.format(rounded, #fix(10));
    trimTrailingZeros(txt);
  };

};
