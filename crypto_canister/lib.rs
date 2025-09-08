use serde_bytes::ByteBuf;
pub type VetKeyPublicKey = ByteBuf;
use ic_cdk::management_canister::{VetKDCurve, VetKDDeriveKeyArgs, VetKDKeyId, VetKDPublicKeyArgs};
use ic_cdk::{init, update};
use ic_stable_structures::memory_manager::{MemoryId, MemoryManager, VirtualMemory};
use ic_stable_structures::{Cell as StableCell, DefaultMemoryImpl};
use ic_vetkeys::{DerivedPublicKey, EncryptedVetKey, VetKey};
use std::cell::RefCell;

type Memory = VirtualMemory<DefaultMemoryImpl>;

thread_local! {
    static MEMORY_MANAGER: RefCell<MemoryManager<DefaultMemoryImpl>> =
        RefCell::new(MemoryManager::init(DefaultMemoryImpl::default()));

    static IBE_PUBLIC_KEY: RefCell<Option<VetKeyPublicKey>> = const { RefCell::new(None) };

    static KEY_NAME: RefCell<StableCell<String, Memory>> =
        RefCell::new(StableCell::init(
            MEMORY_MANAGER.with(|m| m.borrow().get(MemoryId::new(0))),
            String::new(),
        ).expect("failed to initialize key name"));
}

const DOMAIN_SEPARATOR: &str = "basic_timelock_ibe_example_dapp";

#[init]
fn init(key_name_string: String) {
    KEY_NAME.with_borrow_mut(|key_name| {
        key_name.set(key_name_string).expect("failed to set key name");
    });
}

#[update]
async fn get_ibe_public_key() -> VetKeyPublicKey {
    if let Some(key) = IBE_PUBLIC_KEY.with_borrow(|key| key.clone()) {
        return key;
    }

    let request = VetKDPublicKeyArgs {
        canister_id: None,
        context: DOMAIN_SEPARATOR.as_bytes().to_vec(),
        key_id: key_id(),
    };

    let result = ic_cdk::management_canister::vetkd_public_key(&request)
        .await
        .expect("call to vetkd_public_key failed");

    IBE_PUBLIC_KEY.with_borrow_mut(|key| {
        key.replace(VetKeyPublicKey::from(result.public_key.clone()));
    });

    VetKeyPublicKey::from(result.public_key)
}

#[update]
async fn decrypt_vetkey(identity: Vec<u8>) -> Vec<u8> {
    let dummy_seed = vec![0; 32];
    let transport_secret_key = ic_vetkeys::TransportSecretKey::from_seed(dummy_seed.clone())
        .expect("failed to create transport secret key");

    let request = VetKDDeriveKeyArgs {
        context: DOMAIN_SEPARATOR.as_bytes().to_vec(),
        input: identity.clone(),
        key_id: key_id(),
        transport_public_key: transport_secret_key.public_key().to_vec(),
    };

    let result = ic_cdk::management_canister::vetkd_derive_key(&request)
        .await
        .expect("call to vetkd_derive_key failed");

    let ibe_public_key =
        DerivedPublicKey::deserialize(&get_ibe_public_key().await.into_vec()).unwrap();
    let encrypted_vetkey = EncryptedVetKey::deserialize(&result.encrypted_key).unwrap();

    let ibe_decryption_key = encrypted_vetkey
        .decrypt_and_verify(&transport_secret_key, &ibe_public_key, identity.as_ref())
        .expect("failed to decrypt ibe key");

    ibe_decryption_key.serialize().to_vec()
}

#[update]
async fn decrypt_ciphertext(ibe_decryption_key: Vec<u8>, ciphertexts: Vec<Vec<u8>>) -> Vec<Option<Vec<u8>>> {
    let vetkey = match VetKey::deserialize(&ibe_decryption_key) {
        Ok(k) => k,
        Err(_) => return vec![None; ciphertexts.len()],
    };

    ciphertexts
        .into_iter()
        .map(|ciphertext| {
            match ic_vetkeys::IbeCiphertext::deserialize(&ciphertext) {
                Ok(c) => match c.decrypt(&vetkey) {
                    Ok(plain) => Some(plain),
                    Err(_) => None,
                },
                Err(_) => None,
            }
        })
        .collect()
}


fn key_id() -> VetKDKeyId {
    VetKDKeyId {
        curve: VetKDCurve::Bls12_381_G2,
        name: KEY_NAME.with_borrow(|key_name| key_name.get().clone()),
    }
}

// In the following, we register a custom getrandom implementation because
// otherwise getrandom (which is a dependency of some other dependencies) fails to compile.
// This is necessary because getrandom by default fails to compile for the
// wasm32-unknown-unknown target (which is required for deploying a canister).
// Our custom implementation always fails, which is sufficient here because
// the used RNGs are _manually_ seeded rather than by the system.
#[cfg(all(
    target_arch = "wasm32",
    target_vendor = "unknown",
    target_os = "unknown"
))]
getrandom::register_custom_getrandom!(always_fail);
#[cfg(all(
    target_arch = "wasm32",
    target_vendor = "unknown",
    target_os = "unknown"
))]
fn always_fail(_buf: &mut [u8]) -> Result<(), getrandom::Error> {
    Err(getrandom::Error::UNSUPPORTED)
}

#[update]
async fn encrypted_symmetric_key_for_user(transport_public_key: Vec<u8>) -> Vec<u8> {
    let input = ic_cdk::api::msg_caller().as_slice().to_vec();

    let request = VetKDDeriveKeyArgs {
        context: DOMAIN_SEPARATOR.as_bytes().to_vec(),
        input,
        key_id: key_id(),
        transport_public_key,
    };

    let result = ic_cdk::management_canister::vetkd_derive_key(&request)
        .await
        .expect("call to vetkd_derive_key failed");

    result.encrypted_key
}

ic_cdk::export_candid!();
