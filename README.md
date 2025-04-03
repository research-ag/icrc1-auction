# ICRC-1 Auction

An auction canister for selling/buying ICRC1 fungible tokens

## Canister id-s

Auction development backend: `z4s7u-byaaa-aaaao-a3paa-cai`

Auction production backend: `farwr-jqaaa-aaaao-qj4ya-cai`


## Reproducible build

This applies only to auction backend canister.

The setup ensures that the same source code always generates the same Wasm module, with a consistent module hash.
This allows users to verify the canisters that they interact with.
To do so, the user clones the repo, runs the reproducible build process and compares the resulting Wasm module hash
against the module hash of the deployed canister which is always publicly visible.

### How It Works

We use docker to guarantee a consistent build environment.
This allows to reproduce the exact same Wasm module even on different machine architectures.

The repository is used by three different roles in the following ways:

* Developer: uses this repo as a template for the canister repo, then develops the canister as usual.

* Deployer: runs the reproducible build in the canister repo, then deploys the resulting Wasm module.

* Verifier: runs the reproducible build in the canister repo, then compares the resulting module hash against the deployed canister.

The repository is structured to make verification as easy possible.
For example:

* have minimal requirements (only docker)
* be easy to use (run a single command)
* be fast

### Prerequisites

#### Docker

The verifier and deployer need `docker` installed and running.
The developer does not necessarily need `docker`.

On Mac, it is recommended to install `colima` from https://github.com/abiosoft/colima.
When using `colima` it is ok to use value `host` in the `--arch`.
This is also the default so the `--arch` option can be omitted.

#### dfx

The deployer and developer need `dfx`, the verifier does _not_.
The deployer uses `dfx` for its deployment commands, not for building.
The developer uses `dfx` normally as in the usual development cycle.

#### Non-requirements

Notably, the verifier does _not_ need dfx, moc or mops installed.
Everything needed is contained in the docker image.
Similarly, the deployer does not need moc or mops.

### Usage by verifier

Clone the canister repo:

```bash
git clone git@github.com:research-ag/icrc1-auction.git
cd icrc1-auction
```

#### Fast verification

```
docker-compose run --rm wasm
```

The fast verification pulls a base docker image from a registry and then builds a project-specific Docker image on top of it.

The output should look similarly to this:
```
79b15176dc613860f35867828f40e7d6db884c25a5cfd0004f49c3b4b0b3fd5c  out/out_Linux_x86_64.wasm
```
This is the hash that needs to be compared against the module hash of the deployed canister.

The base docker image is optimized for size and is 76 MB large.

Fast verification from scratch, i.e. including downloading the base image, takes less than 10 seconds when run on this repo
(with an empty actor).

#### Compare module hash

The module hash of a deployed canister can be obtained by dfx with:

```
dfx canister --ic info <canister id>
```

or can be seen on the dashboard https://dashboard.internetcomputer.org/canister/<canister id>.

#### Re-verification

If any verification has been run before and the source code has been modified since then,
for example by checking out a new commit, then:

```
docker-compose run --rm --build wasm
```

As a rule, each time the source code, the did file (did/icrc1_auction.did) or the dependencies (mops.toml) get modified
we have to add the `--build` option to the next run.

#### Full verification

```
docker-compose build base
docker-compose run --rm --build wasm
```

Full verification builds the base image locally so that we are not trusting the registry.
The above command sequence works in all cases - it does not matter if fast verification has been run before or not.

#### Fast verification again

If after full verification we want to try fast verification again then:

```
docker-compose pull base
docker-compose run --rm --build wasm
```

This pulls the base image from the registry.

### Usage by deployer

Clone the repo and run any verification like the verifier.
The generated Wasm module is available in the file `out/out_Linux_x86_64.wasm`.

#### First deployment

Create and install the canister with:

```
dfx canister --ic install <canister_id> --wasm out/out_Linux_x86_64.wasm --argument="(opt principal \"cngnf-vqaaa-aaaar-qag4q-cai\", opt principal \"2vxsx-fae\")"
```

#### Reinstall

```
dfx canister --ic install <canister_id> --wasm out/out_Linux_x86_64.wasm --mode reinstall --argument="(opt principal \"cngnf-vqaaa-aaaar-qag4q-cai\", opt principal \"2vxsx-fae\")"
```

#### Upgrade

```
dfx canister --ic install <canister_id> --wasm out/out_Linux_x86_64.wasm --mode upgrade -y --argument="(opt principal \"cngnf-vqaaa-aaaar-qag4q-cai\", opt principal \"2vxsx-fae\")"
```

Note that checking backwards compatibility of the canister's public API or the canister's stable variables is not possible.
Normally, dfx offers such a check but it can only work if the old and new canister versions were both built with dfx.
This is not the case because we use the reproducible build process.
Hence, we supress the backwards compatibility check with the `-y` option.


## Local setup

It is assumed that you have:
- Dfinity SDK installed
- NodeJS installed

Once you have cloned the repository, follow this process in your terminal:

1) In your project directory, run this command to install npm dependencies:
```
npm install
```

2) Start local Internet Computer replica:
```
dfx start --clean --background
```

3) Create canisters:

```
npm run create
```

4) If you want to use mocked ICRC1 ledger as quote ledger for debug purposes, put just created `icrc1_ledger_mock`
   canister id into `dfx.json::icrc1_auction->init_arg->first principal`

5) Setup and deploy canisters locally
```
npm run setup
```

6) Now you can use auction locally. Mocked ICRC1 ledger allows to create tokens out of thin air using `issueTokens` 
function. You should create at least one additional ICRC1 ledger in order to be able to place any bid/ask. This repo 
provides additional canister `icrc1_ledger_mock_2`, which you can register as another ICRC1 ledger in auction for testing

7) To start frontend in development mode, run: 
```
CANISTER_ID_ICRC1_AUCTION=<canister_id> npm run dev:frontend
```
Replace `<canister_id>` with your local auction canister id
