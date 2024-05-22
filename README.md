# ICRC-1 Auction

An auction canister for selling/buying ICRC1 fungible tokens


## Local setup

It is assumed that you have:
- Dfinity SDK installed
- NodeJS installed

Once you have cloned the repository, follow this process in your terminal:
1. In your project directory, run this command to install npm dependencies:
```
npm install
```
2. Start local Internet Computer replica:
```
dfx start --clean --background
```
3. Setup and deploy canisters locally
```
npm run setup
```

4. Call function `init` on auction canister
