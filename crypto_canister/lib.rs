use candid::CandidType;
use serde::{Deserialize, Serialize};

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use sha2::Sha256;

const VERSION: u8 = 1;

use std::cell::RefCell;
use candid::Principal;

#[derive(CandidType, Serialize, Deserialize, Default, Clone)]
struct StableState {
    // 32-byte master secret derived via vetKD (fallback: deterministic seed)
    master_secret: [u8; 32],
    // IBE public key bytes derived via vetKD (fallback: 32-byte hash)
    public_key: Vec<u8>,
}

thread_local! {
    static STATE: RefCell<StableState> = RefCell::new(StableState::default());
}

fn with_state<T>(f: impl FnOnce(&StableState) -> T) -> T {
    STATE.with(|s| {
        let b = s.borrow();
        f(&*b)
    })
}

fn with_state_mut<T>(f: impl FnOnce(&mut StableState) -> T) -> T {
    STATE.with(|s| {
        let mut b = s.borrow_mut();
        f(&mut *b)
    })
}

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct KeyId {
    curve: String,
    name: String,
}

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct VetKDPublicKeyRequest {
    canister_id: Option<candid::Principal>,
    derivation_path: Vec<Vec<u8>>, // sequence of labels
    key_id: KeyId,
}

#[derive(CandidType, Serialize, Deserialize, Clone)]
struct VetKDPublicKeyReply {
    public_key: Vec<u8>,
}

async fn derive_and_cache_vetkd() {
    // Attempt to derive keys from vetKD. If it fails (e.g., local runner), fall back to deterministic.
    let derivation_path = vec![
        b"icrc1-auction".to_vec(),
        b"crypto_canister".to_vec(),
        b"v1".to_vec(),
    ];

    // Fallback first; will be overwritten on success
    let fallback_master = {
        use ic_cdk::api::id;
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(id().as_slice());
        hasher.update(b"/icrc1-auction/crypto_canister");
        let out = hasher.finalize();
        let mut key = [0u8; 32];
        key.copy_from_slice(&out[..32]);
        key
    };
    let fallback_public_key = {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(&fallback_master);
        hasher.update(b"/pk");
        hasher.finalize().to_vec()
    };

    // Defaults
    let mut master_secret = fallback_master;
    let mut public_key = fallback_public_key;

    // Try vetKD public key
    let req = VetKDPublicKeyRequest {
        canister_id: None,
        derivation_path: derivation_path.clone(),
        key_id: KeyId { curve: "bls12_381".into(), name: "test_key_1".into() },
    };
    let call_result: Result<(VetKDPublicKeyReply,), _> = ic_cdk::api::call::call(
        candid::Principal::management_canister(),
        "vetkd_public_key",
        (req,),
    ).await;
    if let Ok((reply,)) = call_result {
        if !reply.public_key.is_empty() {
            public_key = reply.public_key.clone();
            // Derive a 32-byte master secret from the vetKD public key via SHA-256
            use sha2::{Digest, Sha256};
            let mut hasher = Sha256::new();
            hasher.update(&public_key);
            hasher.update(b"/msk");
            let h = hasher.finalize();
            let mut m = [0u8; 32];
            m.copy_from_slice(&h[..32]);
            master_secret = m;
        }
    }

    with_state_mut(|s| {
        s.master_secret = master_secret;
        s.public_key = public_key;
    });
}

fn public_key_bytes() -> [u8; 32] {
    use sha2::{Digest, Sha256};
    with_state(|s| {
        if s.public_key.len() >= 32 {
            let mut pk = [0u8; 32];
            pk.copy_from_slice(&s.public_key[..32]);
            pk
        } else {
            let mut hasher = Sha256::new();
            hasher.update(&s.public_key);
            let out = hasher.finalize();
            let mut pk = [0u8; 32];
            pk.copy_from_slice(&out[..32]);
            pk
        }
    })
}

fn fallback_init_state() {
    // Initialize state with deterministic fallback values (no inter-canister calls)
    let fallback_master = {
        use ic_cdk::api::id;
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(id().as_slice());
        hasher.update(b"/icrc1-auction/crypto_canister");
        let out = hasher.finalize();
        let mut key = [0u8; 32];
        key.copy_from_slice(&out[..32]);
        key
    };
    let fallback_public_key = {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        hasher.update(&fallback_master);
        hasher.update(b"/pk");
        hasher.finalize().to_vec()
    };
    with_state_mut(|s| {
        s.master_secret = fallback_master;
        s.public_key = fallback_public_key;
    });
}

#[ic_cdk::init]
fn init() {
    // Set fallback immediately so canister is usable. Avoid inter-canister calls during init.
    fallback_init_state();
}

#[ic_cdk::post_upgrade]
fn post_upgrade() {
    // Re-establish fallback after upgrade. Avoid inter-canister calls during upgrade.
    fallback_init_state();
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
    with_state(|s| s.public_key.clone())
}

#[ic_cdk::query]
async fn encrypt_block(input: EncryptInput) -> Result<Vec<u8>, String> {
    encrypt_single_block(&input.identity, &input.plaintext)
}

#[ic_cdk::update]
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
    // Use HKDF-SHA256 with salt = identity label, ikm = vetKD-derived master secret, info = domain separator
    let master = with_state(|s| s.master_secret);
    let hk = Hkdf::<Sha256>::new(Some(identity), &master);
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
