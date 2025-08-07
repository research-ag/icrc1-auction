use candid::CandidType;
use serde::{Deserialize, Serialize};

#[derive(CandidType, Serialize, Deserialize)]
struct DecryptionInput {
    private_key: Vec<u8>,
    data_blocks: Vec<Vec<u8>>,
}

#[derive(CandidType, Serialize, Deserialize)]
struct DecryptionResult {
    decrypted_blocks: Vec<Vec<u8>>,
    success: bool,
    error_message: String,
}

#[ic_cdk::update]
async fn get_public_key() -> Vec<u8> {
    // Return a dummy public key for testing
    vec![1, 2, 3, 4, 5]
}

#[ic_cdk::update]
async fn decrypt_blocks(input: DecryptionInput) -> DecryptionResult {
    let mut decrypted_blocks = Vec::new();
    let mut had_error = false;
    let mut error_msg = String::new();

    for block in input.data_blocks {
        match decrypt_single_block(&input.private_key, &block) {
            Ok(decrypted) => decrypted_blocks.push(decrypted),
            Err(e) => {
                had_error = true;
                error_msg = format!("Decryption error: {}", e);
                break;
            }
        }
    }

    DecryptionResult {
        decrypted_blocks,
        success: !had_error,
        error_message: error_msg,
    }
}

fn decrypt_single_block(_private_key: &[u8], encrypted_data: &[u8]) -> Result<Vec<u8>, String> {
    Ok(encrypted_data.to_vec())
}

ic_cdk::export_candid!();
