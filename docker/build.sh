#!/bin/bash

$(mops toolchain bin moc) src/icrc1_auction_api.mo -o out.wasm -c --debug --public-metadata candid:service --public-metadata candid:args $(mops sources)
ic-wasm out.wasm -o out.wasm shrink
if [ -f service.did ]; then
    ic-wasm out.wasm -o out.wasm metadata candid:service -f service.did -v public
fi
sha256sum out.wasm

