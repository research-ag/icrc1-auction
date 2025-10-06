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

  public type Crypto = actor {
    decrypt_vetkey : (identity : Blob) -> async Blob;
    decrypt_ciphertext : (ibe_decryption_key : Blob, data_blocks : [Blob]) -> async [?Blob];
  };

  public func decryptVetKey(cryptoCanisterId : Principal, identity : Blob) : async* Blob {
    let crypto : Crypto = actor (Principal.toText(cryptoCanisterId));
    await crypto.decrypt_vetkey(identity);
  };

  public func decryptOrderBooks(
    cryptoCanisterId : Principal,
    vetKey : Blob,
    encryptedOrderBooks : [T.EncryptedOrderBook],
  ) : async* [?[T.DecryptedOrderData]] {
    let crypto : Crypto = actor (Principal.toText(cryptoCanisterId));

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
      let chunkSize = 10;

      let total = encryptedOrderBooks.size();
      let fullChunks = total / chunkSize;
      let remainder = total % chunkSize;

      var results = VarArray.tabulate<?Blob>(total, func(i) = null);
      var offset = 0;
      while (offset < total) {
        let len = Nat.min(chunkSize, total - offset);
        let chunk = Array.tabulate<Blob>(len, func(j) = encryptedOrderBooks[offset + j].1);
        let part = await crypto.decrypt_ciphertext(vetKey, chunk);
        for (j in part.keys()) {
          results[offset + j] := part[j];
        };
        offset += len;
      };
      Array.fromVarArray<?Blob>(results);
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
