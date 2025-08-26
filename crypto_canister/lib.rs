use candid::CandidType;
use serde::{Deserialize, Serialize};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

const VERSION: u8 = 1;

// Master secret used to derive the public key and decryption keys.
// In a production setup this should be derived from the IC vetKD or secure seed storage.
// For the purposes of this repository and tests we derive it deterministically from the canister id.
fn master_secret() -> [u8; 32] {
    use ic_cdk::api::id;
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(id().as_slice());
    hasher.update(b"/icrc1-auction/crypto_canister");
    let out = hasher.finalize();
    let mut key = [0u8; 32];
    key.copy_from_slice(&out[..32]);
    key
}

fn public_key_bytes() -> [u8; 32] {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(master_secret());
    hasher.update(b"/pk");
    let out = hasher.finalize();
    let mut pk = [0u8; 32];
    pk.copy_from_slice(&out[..32]);
    pk
}

#[derive(CandidType, Serialize, Deserialize)]
struct DecryptionInput {
    // Identity/timelock label as bytes (e.g., UTF-8 timestamp)
    private_key: Vec<u8>,
    data_blocks: Vec<Vec<u8>>,
}

#[derive(CandidType, Serialize, Deserialize)]
enum DecryptionResult {
    #[serde(rename = "Ok")]
    Ok(Vec<Vec<u8>>),
    #[serde(rename = "Err")]
    Err(String),
}

#[derive(CandidType, Serialize, Deserialize)]
struct EncryptInput {
    identity: Vec<u8>,
    plaintext: Vec<u8>,
}

#[ic_cdk::query]
async fn get_public_key() -> Vec<u8> {
    public_key_bytes().to_vec()
}

#[ic_cdk::query]
async fn encrypt_block(input: EncryptInput) -> Result<Vec<u8>, String> {
    encrypt_single_block(&input.identity, &input.plaintext)
}

#[ic_cdk::query]
async fn decrypt_blocks(input: DecryptionInput) -> DecryptionResult {
    let mut decrypted_blocks = Vec::new();

    for block in input.data_blocks {
        match decrypt_single_block(&input.private_key, &block) {
            Ok(decrypted) => decrypted_blocks.push(decrypted),
            Err(e) => {
                return DecryptionResult::Err(format!("Decryption error: {}", e));
            }
        }
    }

    DecryptionResult::Ok(decrypted_blocks)
}

fn derive_key_nonce(identity: &[u8]) -> (Key, Nonce) {
    // Use HKDF-SHA256 with salt = public key bytes, ikm = identity, info = domain separator
    let pk = public_key_bytes();
    let hk = Hkdf::<Sha256>::new(Some(&pk), identity);
    let mut out = [0u8; 44];
    hk.expand(b"icrc1-auction:ibe", &mut out)
        .expect("HKDF expand failed");
    let key = Key::from_slice(&out[0..32]);
    let nonce = Nonce::from_slice(&out[32..44]);
    (key.clone(), *nonce)
}

fn encrypt_single_block(identity: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let (key, nonce) = derive_key_nonce(identity);
    let cipher = ChaCha20Poly1305::new(&key);
    match cipher.encrypt(&nonce, plaintext) {
        Ok(mut ct) => {
            let mut out = Vec::with_capacity(1 + 12 + ct.len());
            out.push(VERSION);
            out.extend_from_slice(nonce.as_slice());
            out.append(&mut ct);
            Ok(out)
        }
        Err(_) => Err("Encryption failed".into()),
    }
}

fn decrypt_single_block(identity: &[u8], encrypted_data: &[u8]) -> Result<Vec<u8>, String> {
    if encrypted_data.is_empty() {
        return Ok(Vec::new());
    }
    // If first byte is VERSION and length is sufficient, treat as encrypted; otherwise treat as legacy plaintext.
    if encrypted_data[0] == VERSION {
        if encrypted_data.len() < 1 + 12 + 16 {
            return Err("Ciphertext too short".into());
        }
        let nonce_bytes = &encrypted_data[1..13];
        let ct = &encrypted_data[13..];
        let (key, expected_nonce) = derive_key_nonce(identity);
        if nonce_bytes != expected_nonce.as_slice() {
            // Nonce mismatch indicates wrong identity; still attempt decryption to produce a clear error
        }
        let cipher = ChaCha20Poly1305::new(&key);
        let nonce = Nonce::from_slice(nonce_bytes);
        return cipher
            .decrypt(nonce, ct)
            .map_err(|_| "Decryption failed (bad identity or corrupted data)".into());
    }
    // Legacy passthrough: treat as plaintext
    Ok(encrypted_data.to_vec())
}

ic_cdk::export_candid!();
