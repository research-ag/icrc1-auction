import { Actor, createIdentity, PocketIc } from '@hadronous/pic';

import {
  _SERVICE as LService,
  idlFactory as L_IDL,
  init as lInit,
} from '../declarations/icrc1_ledger_mock/icrc1_ledger_mock.did';
import {
  _SERVICE as AService,
  AuctionQuerySelection,
  idlFactory as A_IDL,
  init as aInit,
} from '../declarations/icrc1_auction/icrc1_auction_development.did';
import { _SERVICE as CService, idlFactory as C_IDL, init as cInit } from '../declarations/crypto/crypto.did';
import { IDL } from '@dfinity/candid';
import { resolve } from 'node:path';
import { Principal } from '@dfinity/principal';
import { Identity } from '@dfinity/agent';
import { readFileSync } from "fs";
import { tmpdir } from "os";

describe('ICRC1 Auction', () => {
  let serverUrl: string;
  let pic: PocketIc;

  let quoteLedgerPrincipal!: Principal;
  let ledger1Principal!: Principal;
  let ledger2Principal!: Principal;
  let auctionPrincipal!: Principal;

  let quoteLedger: Actor<LService>;
  let ledger1: Actor<LService>;
  let ledger2: Actor<LService>;
  let auction: Actor<AService>;
  let cryptoCanister: Actor<CService>;

  const controller = createIdentity('controller');
  const admin = createIdentity('admin');
  const user = createIdentity('user');

  const startNewAuctionSession = async () => {
    const expectedCounter = await auction.nextSession().then(({ counter }) => counter) + 1n;
    await pic.advanceTime(30 * 60_000);
    await pic.tick();
    let retries = 20;
    while (await auction.nextSession().then(({ counter }) => counter) < expectedCounter) {
      await pic.tick();
      retries--;
      if (retries == 0) {
        throw new Error('Could not start new auction session');
      }
    }
  };
  const ledgerByPrincipal = (p: Principal): Actor<LService> => {
    switch (p.toText()) {
      case (quoteLedgerPrincipal.toText()):
        return quoteLedger;
      case (ledger1Principal.toText()):
        return ledger1;
      case (ledger2Principal.toText()):
        return ledger2;
    }
    return null!;
  };

  const mintDeposit = async (identity: Identity, amount: number = 0, ledger = quoteLedgerPrincipal) => {
    await ledgerByPrincipal(ledger).issueTokens({
      owner: auctionPrincipal,
      subaccount: await auction.principalToSubaccount(identity.getPrincipal()),
    }, BigInt(amount));
    auction.setIdentity(identity);
  };

  const prepareDeposit = async (identity: Identity, token: Principal = quoteLedgerPrincipal, amount = 500_000_000) => {
    await mintDeposit(identity, amount, token);
    await auction.icrc84_notify({ token });
  };

  const queryCredit = async (token: Principal) => {
    return (await auction.icrc84_query([token]))[0][1].credit;
  }

  const auctionQueryEmpty: AuctionQuerySelection = {
    bids: [],
    credits: [],
    asks: [],
    dark_order_books: [],
    deposit_history: [],
    price_history: [],
    immediate_price_history: [],
    transaction_history: [],
    session_numbers: [],
    last_prices: [],
    last_immediate_prices: [],
    order_book_info: [],
    immediate_order_book_info: [],
    reversed_history: [],
  };

  const encryptOrders = async (
    orders: {
      kind: "ask" | "bid",
      volume: number,
      price: number
    }[]): Promise<[Uint8Array, Uint8Array | number[]]> => {

    async function encryptIBE(data: Uint8Array, nextSessionTimestamp: number): Promise<Uint8Array> {
      // we use mocked encryption. Return pure data here
      return data
    }

    async function encryptLocal(data: Uint8Array, nextSessionTimestamp: number): Promise<Uint8Array> {
      return data;
    }

    const text = orders.map(v => v.kind + ':' + v.volume + ':' + v.price).join(";");
    const data = Uint8Array.from(Buffer.from(text, 'utf-8'));
    return [await encryptLocal(data, 0), await encryptIBE(data, 0)];
  };

  beforeAll(() => {
    serverUrl = readFileSync(resolve(tmpdir(), 'pic_server_url.txt'), 'utf-8');
  });

  beforeEach(async () => {
    pic = await PocketIc.create(serverUrl);
    await pic.setTime(1711029457000); // mock time to be 21.03.2024 13:57:37.000 UTC

    const setupLedgerCanister = () => pic.setupCanister({
      wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_ledger_mock/icrc1_ledger_mock.wasm'),
      arg: IDL.encode(lInit({ IDL }), [[], []]),
      sender: controller.getPrincipal(),
      idlFactory: L_IDL,
    });

    let f = await setupLedgerCanister();
    quoteLedgerPrincipal = f.canisterId;
    quoteLedger = f.actor as any;
    quoteLedger.setIdentity(user);

    f = await setupLedgerCanister();
    ledger1Principal = f.canisterId;
    ledger1 = f.actor as any;
    ledger1.setIdentity(user);

    f = await setupLedgerCanister();
    ledger2Principal = f.canisterId;
    ledger2 = f.actor as any;
    ledger2.setIdentity(user);

    f = await pic.setupCanister({
      wasm: resolve(__dirname, '../.dfx/local/canisters/crypto_mock/crypto_mock.wasm'),
      arg: IDL.encode(cInit({ IDL }), ["123qwe"]),
      sender: controller.getPrincipal(),
      idlFactory: C_IDL,
    });
    let cryptoCanisterId = f.canisterId;
    cryptoCanister = f.actor as any;

    f = await pic.setupCanister({
      wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction_development/icrc1_auction_development.wasm'),
      arg: IDL.encode(aInit({ IDL }), [[quoteLedgerPrincipal], [admin.getPrincipal()], [cryptoCanisterId]]),
      sender: controller.getPrincipal(),
      idlFactory: A_IDL,
    });
    auctionPrincipal = f.canisterId;
    auction = f.actor as any;
    auction.setIdentity(admin);

    let res = (await auction.registerAsset(ledger1Principal, 1_000n) as any).Ok;
    expect(res).toEqual(1n); // 0n is quote asset id
    res = (await auction.registerAsset(ledger2Principal, 1_000n) as any).Ok;
    expect(res).toEqual(2n);

    auction.setIdentity(user);

    await startNewAuctionSession();
  });

  afterEach(async () => {
    if (pic) {
      await pic.tearDown();
    }
  });

  describe('canister installation', () => {
    test('should fail on first installation without arguments', async () => {
      const p = await pic.createCanister({
        sender: controller.getPrincipal(),
      });
      await expect(pic.installCode({
        canisterId: p,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction_development/icrc1_auction_development.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], [], []]),
        sender: controller.getPrincipal(),
      })).rejects.toThrow(`Error from Canister ${p.toText()}: Canister called \`ic0.trap\` with message: Quote ledger principal not provided.
Consider gracefully handling failures from this canister or altering the canister to handle exceptions. See documentation: http://internetcomputer.org/docs/current/references/execution-errors#trapped-explicitly`);
    });

    test('should expose ledger principals', async () => {
      expect((await auction.getQuoteLedger()).toText()).toBe(quoteLedgerPrincipal.toText());
      let ledgers = await auction.icrc84_supported_tokens();
      expect(ledgers[0].toText()).toBe(quoteLedgerPrincipal.toText());
      expect(ledgers[1].toText()).toBe(ledger1Principal.toText());
    });

    test('should upgrade canister without arguments', async () => {
      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction_development/icrc1_auction_development.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], [], []]),
        sender: controller.getPrincipal(),
      });
      expect((await auction.getQuoteLedger()).toText()).toBe(quoteLedgerPrincipal.toText());
      let ledgers = await auction.icrc84_supported_tokens();
      expect(ledgers[0].toText()).toBe(quoteLedgerPrincipal.toText());
      expect(ledgers[1].toText()).toBe(ledger1Principal.toText());
    });

    test('should ignore arguments on upgrade', async () => {
      const fakeLedger = createIdentity('fakeLedger');
      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction_development/icrc1_auction_development.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[fakeLedger.getPrincipal()], [], []]),
        sender: controller.getPrincipal(),
      });
      expect((await auction.getQuoteLedger()).toText()).toBe(quoteLedgerPrincipal.toText());
    });

    test('should preserve info during upgrade', async () => {
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, { delayed: null }, 1_500n, 100_000]], []);
      await auction.placeBids([[ledger2Principal, { delayed: null }, 100n, 100_000]], []);
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 1_500_000n, 100_000]], []);

      await startNewAuctionSession();

      auction.setIdentity(user);
      await auction.manageDarkOrderBooks([[
        ledger2Principal,
        [await encryptOrders([{ kind: "ask", volume: 1000000, price: 42.5 }, {
          kind: "bid",
          volume: 12300,
          price: 13.2
        }])]
      ]], []);

      // check info before upgrade
      auction.setIdentity(user);
      expect(await auction.nextSession().then(({ counter }) => counter)).toEqual(3n);
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(339_000_000n); // 500m - 150m paid - 11m locked
      expect(await queryCredit(ledger1Principal)).toEqual(1_500n);
      expect((await auction.auction_query(
        [ledger2Principal],
        { ...auctionQueryEmpty, bids: [true] }
      )).bids).toHaveLength(1);
      expect((await auction.auction_query(
        [ledger2Principal],
        { ...auctionQueryEmpty, dark_order_books: [true] }
      )).dark_order_books).toHaveLength(1);
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 100 `);

      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction_development/icrc1_auction_development.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], [], []]),
        sender: controller.getPrincipal(),
      });

      // check info after upgrade
      expect(await auction.nextSession().then(({ counter }) => counter)).toEqual(3n);
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(339_000_000n);
      expect(await queryCredit(ledger1Principal)).toEqual(1_500n);
      expect((await auction.auction_query([ledger2Principal], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(1);
      expect((await auction.auction_query(
        [ledger2Principal],
        { ...auctionQueryEmpty, dark_order_books: [true] }
      )).dark_order_books).toHaveLength(1);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 100 `);
    });
  });

  describe('timer', () => {
    test('should conduct new session after 2 minutes', async () => {
      expect(await auction.nextSession().then(({ counter }) => counter)).toBe(1n);
      await startNewAuctionSession();
      expect(await auction.nextSession().then(({ counter }) => counter)).toBe(2n);
      await startNewAuctionSession();
      await startNewAuctionSession();
      expect(await auction.nextSession().then(({ counter }) => counter)).toBe(4n);
    });
  });

  describe('deposit', () => {

    test('should accept deposit on notify', async () => {
      await mintDeposit(user, 10_000);
      expect((await auction.icrc84_query([quoteLedgerPrincipal]))).toHaveLength(0);
      await auction.icrc84_notify({ token: quoteLedgerPrincipal });
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(10_000n);
    });

    test('should return total deposit', async () => {
      await mintDeposit(user, 10_000);
      await quoteLedger.issueTokens({
        owner: auctionPrincipal,
        subaccount: await auction.principalToSubaccount(user.getPrincipal()),
      }, BigInt(5_000));
      const ret = await auction.icrc84_notify({ token: quoteLedgerPrincipal });
      expect(ret).toEqual({
        Ok: {
          credit: 15000n,
          credit_inc: 15000n,
          deposit_inc: 15000n,
        },
      });
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(15_000n);
    });

    test('should return error if not enough balance', async () => {
      const ret = await auction.icrc84_notify({ token: quoteLedgerPrincipal });
      expect(ret).toEqual({ Err: { NotAvailable: { message: 'Deposit was not detected' } } });
    });

    test('should return error if wrong asset id', async () => {
      const ret = await auction.icrc84_notify({ token: createIdentity('fakeFt').getPrincipal() });
      expect(ret).toEqual({ Err: { NotAvailable: { message: 'Unknown token' } } });
    });

    test('should be able to withdraw deposit', async () => {
      await mintDeposit(user, 999, quoteLedgerPrincipal);
      await auction.icrc84_notify({ token: quoteLedgerPrincipal });
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(999n);
      expect(await quoteLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(0n);

      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 499n,
        token: quoteLedgerPrincipal,
        expected_fee: [],
      });
      expect(res).toHaveProperty('Ok');
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(500n);
      expect(await quoteLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(499n);
    });

    test('withdraw deposit should return insufficient deposit error', async () => {
      await prepareDeposit(user);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 500_000_001n,
        token: quoteLedgerPrincipal,
        expected_fee: [],
      });
      expect(await queryCredit(quoteLedgerPrincipal)).toEqual(500_000_000n);
    });
  });

  describe('orders', () => {

    test('should be able to manage orders via single query', async () => {
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, { delayed: null }, 1_000n, 15_000]], []);
      expect((await auction.auction_query([], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(1);
      let res2 = await auction.manageOrders([{ all: [] }], [
        { bid: [ledger1Principal, { delayed: null }, 1_000n, 15_100] },
        { bid: [ledger1Principal, { delayed: null }, 1_000n, 15_200] },
      ], []);
      expect(res2).toHaveProperty('Ok');
      expect((await auction.auction_query([], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(2);
    });

    test('should reject changes if account revision is wrong', async () => {
      await prepareDeposit(user);
      const rev = (await auction.auction_query([], auctionQueryEmpty)).account_revision;
      const res = await auction.placeBids([[ledger1Principal, { delayed: null }, 1_000n, 15_000]], [rev - 1n]);
      expect(res[0]).toHaveProperty('Err');
      expect((res[0] as any)['Err']).toHaveProperty('AccountRevisionMismatch');
      expect((await auction.auction_query([], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(0);
    });

    test('should accept correct account revision', async () => {
      await prepareDeposit(user);
      const rev = (await auction.auction_query([], auctionQueryEmpty)).account_revision;
      const res = await auction.placeBids([[ledger1Principal, { delayed: null }, 1_000n, 15_000]], [rev]);
      expect(res[0]).toHaveProperty('Ok');
      expect((await auction.auction_query([], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(1);
    });

    test('bids should affect metrics', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, { delayed: null }, 2_000n, 15_000]], []);
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 2000 `);

      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 200_000_000n, 15_000]], []);
      auction.setIdentity(user);
      await startNewAuctionSession();

      expect((await auction.auction_query([ledger1Principal], {
        ...auctionQueryEmpty,
        bids: [true],
      })).bids).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 0 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 0 `);
    });

    test('asks should affect metrics', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);

      const buyer = createIdentity('buyer');
      await prepareDeposit(buyer);
      auction.setIdentity(buyer);
      await auction.placeBids([[ledger1Principal, { delayed: null }, 2_000_000n, 100]], []);

      auction.setIdentity(user);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 2_000_000n, 100]], []);
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`asks_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 1 `);
      expect(metrics).toContain(`asks_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 2000000 `);

      await startNewAuctionSession();

      expect((await auction.auction_query([ledger1Principal], {
        ...auctionQueryEmpty,
        asks: [true],
      })).asks).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`asks_count{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 0 `);
      expect(metrics).toContain(`asks_volume{canister="${shortP}",asset_id="MOCK",order_book="delayed"} 0 `);
    });

  });

  describe('dark order books', () => {

    test('should be able to place and remove dark orders', async () => {
      await prepareDeposit(user);
      await auction.manageDarkOrderBooks([[
        ledger1Principal,
        [await encryptOrders([{ kind: "ask", volume: 1000000, price: 42.5 }, {
          kind: "bid",
          volume: 12300,
          price: 13.2
        }])]
      ]], []);
      let queryResult = (await auction.auction_query([], {
        ...auctionQueryEmpty,
        dark_order_books: [true],
      })).dark_order_books;
      expect(queryResult).toHaveLength(1);
      expect(queryResult[0][0]).toEqual(ledger1Principal);

      await auction.manageDarkOrderBooks([[ledger1Principal, []]], []);

      expect((await auction.auction_query([], {
        ...auctionQueryEmpty,
        asks: [true],
      })).asks).toHaveLength(0);
    });

    test('should lock funds when dark order book set', async () => {
      await prepareDeposit(user, quoteLedgerPrincipal);
      await auction.manageDarkOrderBooks([
        [ledger1Principal, [await encryptOrders([
          { kind: "bid", volume: 10000, price: 10 },
          { kind: "bid", volume: 20000, price: 18 }
        ])]],
        [ledger2Principal, [await encryptOrders([{ kind: "bid", volume: 10000, price: 12 }])]]
      ], []);

      let state = await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal, ledger2Principal],
        { ...auctionQueryEmpty, dark_order_books: [true], credits: [true] }
      );
      expect(state.dark_order_books).toHaveLength(2);
      expect(state.credits[0][1].locked).toEqual(2_000_000n);
    });

    test('should return old dark order book when overwriting', async () => {
      await prepareDeposit(user);
      let encryptedOrdersV1 = await encryptOrders([{ kind: "ask", volume: 1000000, price: 42.5 }, {
        kind: "bid",
        volume: 12300,
        price: 13.2
      }]);
      let resp = await auction.manageDarkOrderBooks([[ledger1Principal, [encryptedOrdersV1]]], []);
      expect(resp).toEqual({ Ok: [[]] });
      let resp2 = await auction.manageDarkOrderBooks([[
        ledger1Principal,
        [await encryptOrders([{ kind: "ask", volume: 1120000, price: 39.5 }, {
          kind: "bid",
          volume: 10300,
          price: 9.2
        }])]
      ]], []);
      expect(resp2).toEqual({ Ok: [[encryptedOrdersV1]] });
    });

    test('should process dark orders', async () => {
      await prepareDeposit(user, quoteLedgerPrincipal, 1_000_000);
      await auction.manageDarkOrderBooks([[ledger1Principal, [await encryptOrders([{
        kind: "bid",
        volume: 10000,
        price: 100
      }])]]], []);
      expect((await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, dark_order_books: [true] }
      )).dark_order_books).toEqual([[ledger1Principal, await encryptOrders([{
        kind: "bid",
        volume: 10000,
        price: 100
      }])]]);

      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal, 10_000);
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 10_000n, 100.0]], []);

      await startNewAuctionSession();

      expect((await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, credits: [true] }
      )).credits).toEqual([
        [quoteLedgerPrincipal, { available: 1_000_000n, locked: 0n, total: 1_000_000n }],
        [ledger1Principal, { available: 0n, locked: 0n, total: 0n }],
      ]);

      auction.setIdentity(user);
      let state = (await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, credits: [true], dark_order_books: [true] }
      ));
      expect(state.credits).toEqual([
        [quoteLedgerPrincipal, { available: 0n, locked: 0n, total: 0n }],
        [ledger1Principal, { available: 10_000n, locked: 0n, total: 10_000n }],
      ]);
      expect(state.dark_order_books).toEqual([]);
    });

    test('should process dark order partially when out of funds', async () => {
      await prepareDeposit(user, quoteLedgerPrincipal, 1_000_000);
      await auction.manageDarkOrderBooks([[ledger1Principal, [await encryptOrders([
        { kind: "bid", volume: 10_000, price: 100 }, // consumes all of the user credits
        { kind: "bid", volume: 10_000, price: 120 }, // will be thrown away as user does not have funds for that
      ])]]], []);

      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal, 20_000);
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 20_000n, 100.0]], []);

      await startNewAuctionSession();
      // check that user bought 10_000
      auction.setIdentity(user);
      let state = (await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, credits: [true], dark_order_books: [true] }
      ));
      expect(state.credits).toEqual([
        [quoteLedgerPrincipal, { available: 0n, locked: 0n, total: 0n }],
        [ledger1Principal, { available: 10_000n, locked: 0n, total: 10_000n }],
      ]);
      expect(state.dark_order_books).toEqual([]);

      // check that seller sold 10_000
      auction.setIdentity(seller);
      state = (await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, credits: [true], asks: [true] }
      ));
      expect(state.credits).toEqual([
        [quoteLedgerPrincipal, { available: 1_000_000n, locked: 0n, total: 1_000_000n }],
        [ledger1Principal, { available: 0n, locked: 10_000n, total: 10_000n }],
      ]);
      expect(state.asks.length).toBe(1);
      expect(state.asks[0][1].volume).toEqual(10_000n);
    });

    test('should remove unfulfilled dark order after auction ran', async () => {
      await prepareDeposit(user, quoteLedgerPrincipal);
      await auction.manageDarkOrderBooks([[ledger1Principal, [await encryptOrders([{
        kind: "bid",
        volume: 10000,
        price: 100
      }])]]], []);

      let state0 = await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, dark_order_books: [true], credits: [true], bids: [true] }
      );
      expect(state0.dark_order_books).toHaveLength(1);
      expect(state0.bids).toHaveLength(0);
      expect(state0.credits[0][1].locked).toEqual(1_000_000n);

      await startNewAuctionSession();

      let state1 = await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, dark_order_books: [true], credits: [true], bids: [true] }
      );
      expect(state1.dark_order_books).toHaveLength(0);
      expect(state1.bids).toHaveLength(0);
      expect(state1.credits[0][1].locked).toEqual(0n);
    });

    test('should remove dark order after auction ran when it could not be parsed', async () => {
      await prepareDeposit(user, quoteLedgerPrincipal);
      await auction.manageDarkOrderBooks([[ledger1Principal, [[[0, 1, 2], [3, 4, 5]]]]], []);
      let state0 = await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, dark_order_books: [true], credits: [true], bids: [true] }
      );
      expect(state0.dark_order_books).toHaveLength(1);
      expect(state0.bids).toHaveLength(0);
      expect(state0.credits[0][1].locked).toEqual(1_000_000n);

      await startNewAuctionSession();

      let state1 = await auction.auction_query(
        [quoteLedgerPrincipal, ledger1Principal],
        { ...auctionQueryEmpty, dark_order_books: [true], credits: [true], bids: [true] }
      );
      expect(state1.dark_order_books).toHaveLength(0);
      expect(state1.bids).toHaveLength(0);
      expect(state1.credits[0][1].locked).toEqual(0n);
    });

  });

  describe('credit', () => {

    test('should return #InsufficientCredit if not registered', async () => {
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_000n,
        token: ledger1Principal,
        expected_fee: [],
      });
      expect(res).toEqual({ Err: { InsufficientCredit: {} } });
    });

    test('should return #InsufficientCredit if not enough credits', async () => {
      await prepareDeposit(user, ledger1Principal, 800);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_000n,
        token: ledger1Principal,
        expected_fee: [],
      });
      expect(res).toEqual({ Err: { InsufficientCredit: {} } });
      expect(await queryCredit(ledger1Principal)).toEqual(800n);
    });

    test('should withdraw credit successfully', async () => {
      await prepareDeposit(user, ledger1Principal, 1_200);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_200n,
        token: ledger1Principal,
        expected_fee: [],
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_200n);
      expect((await auction.icrc84_query([ledger1Principal]))).toHaveLength(0);
    });

    test('should affect metrics', async () => {
      await prepareDeposit(user, ledger1Principal, 1_200);
      const user2 = createIdentity('user2');
      await prepareDeposit(user2, ledger1Principal, 1_200);
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`accounts_count{canister="${shortP}"} 2 `);
      expect(metrics).toContain(`users_count{canister="${shortP}"} 2 `);
      expect(metrics).toContain(`users_with_credits_count{canister="${shortP}"} 2 `);

      const res = await auction.icrc84_withdraw({
        to: { owner: user2.getPrincipal(), subaccount: [] },
        amount: 1_200n,
        token: ledger1Principal,
        expected_fee: [],
      });
      expect(res).toHaveProperty('Ok');

      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`accounts_count{canister="${shortP}"} 1 `);
      expect(metrics).toContain(`users_count{canister="${shortP}"} 2 `);
      expect(metrics).toContain(`users_with_credits_count{canister="${shortP}"} 1 `);
    });

    // TODO uncomment 3 tests below after fixing issue
    test.skip('should return #BadFee if provided fee is wrong', async () => {
      await ledger1.updateFee(BigInt(3));
      await prepareDeposit(user, ledger1Principal, 1_200);
      expect(await queryCredit(ledger1Principal)).toEqual(1197n);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_197n,
        token: ledger1Principal,
        expected_fee: [50n],
      });
      expect(res).toEqual({ Err: { BadFee: { expected_fee: 3n } } });
      expect(await queryCredit(ledger1Principal)).toEqual(1_197n);
    });

    test.skip('should withdraw credit successfully with ICRC1 fee', async () => {
      await ledger1.updateFee(BigInt(3));
      await prepareDeposit(user, ledger1Principal, 1_200);
      expect(await queryCredit(ledger1Principal)).toEqual(1197n);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_197n,
        token: ledger1Principal,
        expected_fee: [],
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_194n);
      expect(await queryCredit(ledger1Principal)).toEqual(0n);
    });

    test.skip('should withdraw credit successfully when provided correct expected fee', async () => {
      await ledger1.updateFee(BigInt(3));
      await prepareDeposit(user, ledger1Principal, 1_200);
      const res = await auction.icrc84_withdraw({
        to: { owner: user.getPrincipal(), subaccount: [] },
        amount: 1_197n,
        token: ledger1Principal,
        expected_fee: [3n],
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_194n);
      expect(await queryCredit(ledger1Principal)).toEqual(0n);
    });
  });

  describe('auction query', () => {
    test('should return various info as single response', async () => {
      await prepareDeposit(user);
      await prepareDeposit(user, ledger1Principal);

      await auction.placeBids([[ledger1Principal, { delayed: null }, 1_500n, 100_000]], []);
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 1_500n, 101_000]], []);
      const buyer = createIdentity('buyer');
      await prepareDeposit(buyer);
      auction.setIdentity(buyer);
      await auction.placeBids([[ledger1Principal, { delayed: null }, 1_500n, 102_000]], []);
      auction.setIdentity(user);


      await startNewAuctionSession();
      await auction.placeAsks([[ledger1Principal, { delayed: null }, 1_500n, 102_000]], []);

      const res = await auction.auction_query([], {
        credits: [true],
        bids: [true],
        asks: [true],
        dark_order_books: [true],
        session_numbers: [true],
        transaction_history: [[1000n, 0n]],
        price_history: [[1000n, 0n, true]],
        immediate_price_history: [],
        deposit_history: [[1000n, 0n]],
        last_prices: [true],
        last_immediate_prices: [true],
        order_book_info: [true],
        immediate_order_book_info: [true],
        reversed_history: [true],
      });

      expect(res.credits).toEqual([
        [ledger1Principal, { total: 499998500n, locked: 1500n, available: 499997000n }],
        [quoteLedgerPrincipal, { total: 651500000n, locked: 150000000n, available: 501500000n }],
      ]);
      expect(res.asks).toEqual([
        [3n, { icrc1Ledger: ledger1Principal, orderBookType: { delayed: null }, volume: 1500n, price: 102000 }],
      ]);
      expect(res.bids).toEqual([
        [0n, { icrc1Ledger: ledger1Principal, orderBookType: { delayed: null }, volume: 1500n, price: 100000 }],
      ]);
      expect(res.session_numbers).toEqual([
        [quoteLedgerPrincipal, 2n],
        [ledger1Principal, 2n],
        [ledger2Principal, 2n],
      ]);
      expect(res.transaction_history).toHaveLength(1);
      expect(res.transaction_history[0][1]).toEqual(1n);
      expect(res.transaction_history[0][2]).toEqual({ ask: null });
      expect(res.transaction_history[0][3]).toEqual(ledger1Principal);
      expect(res.transaction_history[0][4]).toEqual(1500n);
      expect(res.transaction_history[0][5]).toEqual(101000);

      expect(res.price_history).toHaveLength(1);
      expect(res.price_history[0][1]).toEqual(1n);
      expect(res.price_history[0][2]).toEqual(ledger1Principal);
      expect(res.price_history[0][3]).toEqual(1500n);
      expect(res.price_history[0][4]).toEqual(101000);

      expect(res.last_prices).toHaveLength(1);
      expect(res.last_prices[0][1]).toEqual(1n);
      expect(res.last_prices[0][2]).toEqual(ledger1Principal);
      expect(res.last_prices[0][3]).toEqual(1500n);
      expect(res.last_prices[0][4]).toEqual(101000);

      expect(res.deposit_history).toHaveLength(2);
      expect(res.deposit_history[0][1]).toEqual({ deposit: null });
      expect(res.deposit_history[0][2]).toEqual(ledger1Principal);
      expect(res.deposit_history[0][3]).toEqual(500000000n);
      expect(res.deposit_history[1][1]).toEqual({ deposit: null });
      expect(res.deposit_history[1][2]).toEqual(quoteLedgerPrincipal);
      expect(res.deposit_history[1][3]).toEqual(500000000n);

      expect(res.order_book_info).toEqual([
        [ledger1Principal, {
          clearing: { noMatch: null },
          maxBidPrice: [100000], minAskPrice: [102000],
          totalAskVolume: 1500n, totalBidVolume: 1500n
        }],
        [ledger2Principal, {
          clearing: { noMatch: null },
          maxBidPrice: [], minAskPrice: [],
          totalAskVolume: 0n, totalBidVolume: 0n
        }]
      ]);
      expect(res.immediate_order_book_info).toEqual([
        [ledger1Principal, { maxBidPrice: [], minAskPrice: [], totalAskVolume: 0n, totalBidVolume: 0n }],
        [ledger2Principal, { maxBidPrice: [], minAskPrice: [], totalAskVolume: 0n, totalBidVolume: 0n }]
      ]);
    });
    test('should public info to not registered user', async () => {
      await prepareDeposit(user);
      await prepareDeposit(user, ledger1Principal);
      await auction.placeBids([[ledger1Principal, { immediate: null }, 1_500n, 100_000]], []);

      const guest = createIdentity('guest');
      auction.setIdentity(guest);

      const res = await auction.auction_query([], {
        credits: [true],
        bids: [true],
        asks: [true],
        dark_order_books: [true],
        session_numbers: [true],
        transaction_history: [[1000n, 0n]],
        price_history: [[1000n, 0n, true]],
        immediate_price_history: [],
        deposit_history: [[1000n, 0n]],
        last_prices: [true],
        last_immediate_prices: [true],
        order_book_info: [true],
        immediate_order_book_info: [true],
        reversed_history: [true],
      });

      expect(res.credits).toHaveLength(0);
      expect(res.asks).toHaveLength(0);
      expect(res.bids).toHaveLength(0);
      expect(res.transaction_history).toHaveLength(0);
      expect(res.deposit_history).toHaveLength(0);
      expect(res.order_book_info).toEqual([
        [ledger1Principal, {
          clearing: { noMatch: null },
          maxBidPrice: [100000], minAskPrice: [],
          totalAskVolume: 0n, totalBidVolume: 1500n
        }],
        [ledger2Principal, {
          clearing: { noMatch: null },
          maxBidPrice: [], minAskPrice: [],
          totalAskVolume: 0n, totalBidVolume: 0n
        }]
      ]);
      expect(res.immediate_order_book_info).toEqual([
        [ledger1Principal, { maxBidPrice: [100000], minAskPrice: [], totalAskVolume: 0n, totalBidVolume: 1500n }],
        [ledger2Principal, { maxBidPrice: [], minAskPrice: [], totalAskVolume: 0n, totalBidVolume: 0n }]
      ]);
    });
  });
});
