import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Float "mo:core/Float";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";

import T "./types";

module {

  // TODO temporary constant. Check where it is used and refactor appropriately
  public let MOCK_DECRYPTION_KEY : Blob = "\00\01\02";

  public func decryptOrderBooks(encryptedOrderBooks : [T.EncryptedOrderBook], encryptionKey : Blob) : async* [?[T.DecryptedOrderData]] {
    assert encryptionKey == MOCK_DECRYPTION_KEY;

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

    Array.map<T.EncryptedOrderBook, ?[T.DecryptedOrderData]>(
      encryptedOrderBooks,
      func(encryptedOrders) {
        let orders = Text.split(encryptedOrders, #char ';') |> Iter.toArray(_);
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
