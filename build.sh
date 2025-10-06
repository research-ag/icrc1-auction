#!/bin/bash

MOC_GC_FLAGS="--legacy-persistence" ## place any additional flags like compacting-gc, incremental-gc here
MOC_FLAGS="$MOC_GC_FLAGS -no-check-ir --release --public-metadata candid:service --public-metadata candid:args"
OUT=out/out_$(uname -s)_$(uname -m).wasm
mops-cli build --lock --name out src/icrc1_auction_api.mo -- $MOC_FLAGS
cp target/out/out.wasm $OUT
ic-wasm $OUT -o $OUT shrink
if [ -f did/icrc1_auction.did ]; then
    echo "Adding icrc1_auction.did to metadata section."
    ic-wasm $OUT -o $OUT metadata candid:service -f did/icrc1_auction.did -v public
else
    echo "icrc1_auction.did not found. Skipping metadata update."
fi
if [ "$compress" == "yes" ] || [ "$compress" == "y" ]; then
  gzip -nf $OUT
  sha256sum $OUT.gz
else
  sha256sum $OUT
fi
