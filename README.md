# ICRC-1 Auction

An auction canister for selling/buying ICRC1 fungible tokens

## Local setup

It is assumed that you have:

- Dfinity SDK installed
- NodeJS installed
- ic-mops installed

Once you have cloned the repository, follow this process in your terminal:

1. In your project directory, run this command to install npm dependencies:

```
npm install
```

2. Start local Internet Computer replica:

```
dfx start --clean --background
```

3. Create canisters:

```
npm run create
```

4. If you want to use mocked ICRC1 ledger as trusted ledger for debug purposes, put just created `icrc1_ledger_mock`
   canister id into `dfx.json::icrc1_auction->init_arg->first principal`

5. Setup and deploy canisters locally

```
npm run setup
```

6. First installation only: call function `init` on auction canister:

```
dfx canister call icrc1_auction init
```

7. Now you can use auction locally. Mocked ICRC1 ledger allows to create tokens out of thin air using `issueTokens`
   function. You should create at least one additional ICRC1 ledger in order to be able to place any bid/ask. This repo
   provides additional canister `icrc1_ledger_mock_2`, which you can register as another ICRC1 ledger in auction for testing
