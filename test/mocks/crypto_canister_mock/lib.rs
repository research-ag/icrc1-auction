use ic_cdk::{init, update};
use serde_bytes::ByteBuf;

pub type VetKeyPublicKey = ByteBuf;

#[init]
fn init(_key_name_string: String) {
}

#[update]
async fn get_ibe_public_key() -> VetKeyPublicKey {
    VetKeyPublicKey::from(Vec::<u8>::new())
}

#[update]
async fn decrypt(_identity: Vec<u8>, ciphertexts: Vec<Vec<u8>>) -> Vec<Option<Vec<u8>>> {
    ciphertexts.into_iter().map(|c| Some(c)).collect()
}

ic_cdk::export_candid!();
