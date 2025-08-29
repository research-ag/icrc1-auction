import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Error "mo:core/Error";
import Float "mo:core/Float";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Prim "mo:prim";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";

import T "./types";

module {

  public func decryptOrderBooks(
    cryptoCanisterId : Principal,
    privateKey : Blob,
    encryptedOrderBooks : [T.EncryptedOrderBook],
  ) : async* [?[T.DecryptedOrderData]] {
    let crypto : (
      actor {
        decrypt : (identity : Blob, data_blocks : [Blob]) -> async [?Blob];
      }
    ) = actor (Principal.toText(cryptoCanisterId));

    func parseOrder(order : Text) : ?T.DecryptedOrderData {
      let words = Text.split(order, #char ':');

      let kind = switch (words.next()) {
        case (?"ask") #ask;
        case (?"bid") #bid;
        case (_) return null;
      };

      let ?volumeText = words.next() else return null;
      let ?volume = Nat.fromText(volumeText) else return null;

      let ?priceText = words.next() else return null;
      let priceFractionPartLength = switch (Text.split(priceText, #char '.') |> Iter.drop(_, 1) |> _.next()) {
        case (?w) w.size();
        case (null) 0;
      };
      let ?priceNat = Text.split(priceText, #char '.') |> Text.join("", _) |> Nat.fromText(_) else return null;
      let price = Float.fromInt(priceNat) * (10 ** Float.fromInt(-priceFractionPartLength));

      ?{
        kind;
        volume;
        price;
      };
    };

    let decrypted = try {
      await crypto.decrypt(privateKey, Array.map<T.EncryptedOrderBook, Blob>(encryptedOrderBooks, func(_, x) = x));
    } catch (err) {
      Prim.debugPrint("Error while calling crypto canister to decrypt data: " # Error.message(err));
      return Array.tabulate<?[T.DecryptedOrderData]>(encryptedOrderBooks.size(), func(_) = null);
    };

    Array.map<?Blob, ?[T.DecryptedOrderData]>(
      decrypted,
      func(dataOpt) {
        let ?data = dataOpt else return null;
        let ?text = Text.decodeUtf8(data) else return null;
        let orders = Text.split(text, #char ';') |> Iter.toArray(_);
        let ret = VarArray.repeat<T.DecryptedOrderData>({ kind = #ask; volume = 0; price = 0 }, orders.size());
        for (i in orders.keys()) {
          let ?decrypted = parseOrder(orders[i]) else return null;
          ret[i] := decrypted;
        };
        ?Array.fromVarArray<T.DecryptedOrderData>(ret);
      },
    );
  };

};
