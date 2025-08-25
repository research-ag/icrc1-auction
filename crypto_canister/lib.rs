use candid::CandidType;
use serde::{Deserialize, Serialize};

#[derive(CandidType, Serialize, Deserialize)]
struct DecryptionInput {
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

#[ic_cdk::query]
async fn get_public_key() -> Vec<u8> {
    // Return a dummy public key for testing
    vec![1, 2, 3, 4, 5]
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

fn decrypt_single_block(_private_key: &[u8], encrypted_data: &[u8]) -> Result<Vec<u8>, String> {
    Ok(encrypted_data.to_vec())
}

ic_cdk::export_candid!();
