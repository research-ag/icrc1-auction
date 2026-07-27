import { Identity } from '@icp-sdk/core/agent';
import { safeGetCanisterEnv } from '@icp-sdk/core/agent/canister-env';
import { createActor as createCryptoActor } from '@declarations/crypto';
import { DerivedKeyMaterial, DerivedPublicKey, EncryptedVetKey, TransportSecretKey } from '@dfinity/vetkeys';

const AES_GCM_DOMAIN = 'icrc1-auction-aes-gcm';

const kmCache = new Map<string, Promise<DerivedKeyMaterial>>();

export async function getDerivedKeyMaterial(identity: Identity): Promise<DerivedKeyMaterial | null> {
  const principalText = identity.getPrincipal().toText();
  const canisterEnv = safeGetCanisterEnv();
  const CRYPTO_CANISTER_ID = canisterEnv?.['PUBLIC_CANISTER_ID:crypto'];
  if (!CRYPTO_CANISTER_ID) return null;

  if (!kmCache.has(principalText)) {
    kmCache.set(
      principalText,
      (async () => {
        const crypto = createCryptoActor(CRYPTO_CANISTER_ID, {
          agentOptions: {
            identity,
            host: window.location.origin,
            rootKey: canisterEnv?.IC_ROOT_KEY,
          },
        });

        const dpkBytes = new Uint8Array(await crypto.get_ibe_public_key());
        const dpk = DerivedPublicKey.deserialize(dpkBytes);

        const tsk = TransportSecretKey.random();
        const tpk = tsk.publicKeyBytes();

        const enc = new Uint8Array(await (crypto as any).encrypted_symmetric_key_for_user(tpk));
        const encrypted = EncryptedVetKey.deserialize(enc);

        const input = (identity.getPrincipal() as any).toUint8Array();
        const vetKey = encrypted.decryptAndVerify(tsk, dpk, input);

        return await vetKey.asDerivedKeyMaterial();
      })(),
    );
  }

  return kmCache.get(principalText)!;
}

export async function encryptWithVetKD(identity: Identity, plaintext: Uint8Array): Promise<Uint8Array> {
  const km = await getDerivedKeyMaterial(identity);
  if (!km) {
    console.warn("Can't encrypt with VetKD: no derived key material found. Using plaintext instead.");
    return plaintext;
  }
  return km.encryptMessage(plaintext, AES_GCM_DOMAIN);
}

export async function decryptWithVetKD(identity: Identity, ciphertext: Uint8Array): Promise<Uint8Array | null> {
  const km = await getDerivedKeyMaterial(identity);
  if (!km) return null;
  try {
    return await km.decryptMessage(ciphertext, AES_GCM_DOMAIN);
  } catch (_e) {
    console.warn("Can't decrypt with VetKD: invalid ciphertext. Using plaintext instead.", _e);
    return null;
  }
}
