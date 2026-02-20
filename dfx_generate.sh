# this script is for quick re-generation of declarations. Replaces @dfinity imports with @icp-sdk

dfx generate crypto
dfx generate icrc1_auction_development
dfx generate icrc1_ledger_mock

find declarations -type f \( -name "*.ts" -o -name "*.js" \) -print0 | \
  xargs -0 sed -i '' \
    -e 's/@dfinity\/agent/@icp-sdk\/core\/agent/g' \
    -e 's/@dfinity\/candid/@icp-sdk\/core\/candid/g' \
    -e 's/@dfinity\/principal/@icp-sdk\/core\/principal/g'