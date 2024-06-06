import { Actor, createIdentity, PocketIc } from '@hadronous/pic';

import {
  _SERVICE as LService,
  idlFactory as L_IDL,
  init as lInit,
} from '../declarations/icrc1_ledger_mock/icrc1_ledger_mock.did';
import {
  _SERVICE as AService,
  idlFactory as A_IDL,
  init as aInit,
} from '../declarations/icrc1_auction/icrc1_auction.did';
import { IDL } from '@dfinity/candid';
import { resolve } from 'node:path';
import { Principal } from '@dfinity/principal';
import { Identity } from '@dfinity/agent';

describe('ICRC1 Auction', () => {
  let pic: PocketIc;

  let trustedLedgerPrincipal!: Principal;
  let ledger1Principal!: Principal;
  let ledger2Principal!: Principal;
  let auctionPrincipal!: Principal;

  let trustedLedger: Actor<LService>;
  let ledger1: Actor<LService>;
  let ledger2: Actor<LService>;
  let auction: Actor<AService>;

  const controller = createIdentity('controller');
  const admin = createIdentity('admin');
  const user = createIdentity('user');

  const startNewAuctionSession = async () => {
    const expectedCounter = await auction.sessionsCounter() + 1n;
    await pic.advanceTime(24 * 60 * 60_000);
    await pic.tick();
    let retries = 20;
    while (await auction.sessionsCounter() < expectedCounter) {
      await pic.tick();
      retries--;
      if (retries == 0) {
        throw new Error('Could not start new auction session');
      }
    }
  };

  const ledgerByPrincipal = (p: Principal): Actor<LService> => {
    switch (p.toText()) {
      case (trustedLedgerPrincipal.toText()):
        return trustedLedger;
      case (ledger1Principal.toText()):
        return ledger1;
      case (ledger2Principal.toText()):
        return ledger2;
    }
    return null!;
  };

  const mintDeposit = async (identity: Identity, amount: number = 0, ledger = trustedLedgerPrincipal) => {
    await ledgerByPrincipal(ledger).issueTokens({
      owner: auctionPrincipal,
      subaccount: await auction.principalToSubaccount(identity.getPrincipal()),
    }, BigInt(amount));
    auction.setIdentity(identity);
  };

  const prepareDeposit = async (identity: Identity, token: Principal = trustedLedgerPrincipal, amount = 500_000_000) => {
    await mintDeposit(identity, amount, token);
    await auction.icrcX_notify({ token });
  };

  beforeEach(async () => {
    pic = await PocketIc.create();
    await pic.setTime(1711029457000); // mock time to be 21.03.2024 13:57:37.000 UTC

    const setupLedgerCanister = () => pic.setupCanister({
      wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_ledger_mock/icrc1_ledger_mock.wasm'),
      arg: IDL.encode(lInit({ IDL }), []),
      sender: controller.getPrincipal(),
      idlFactory: L_IDL,
    });

    let f = await setupLedgerCanister();
    trustedLedgerPrincipal = f.canisterId;
    trustedLedger = f.actor as any;
    trustedLedger.setIdentity(user);

    f = await setupLedgerCanister();
    ledger1Principal = f.canisterId;
    ledger1 = f.actor as any;
    ledger1.setIdentity(user);

    f = await setupLedgerCanister();
    ledger2Principal = f.canisterId;
    ledger2 = f.actor as any;
    ledger2.setIdentity(user);

    f = await pic.setupCanister({
      wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
      arg: IDL.encode(aInit({ IDL }), [[trustedLedgerPrincipal], [admin.getPrincipal()]]),
      sender: controller.getPrincipal(),
      idlFactory: A_IDL,
    });
    auctionPrincipal = f.canisterId;
    auction = f.actor as any;
    auction.setIdentity(admin);
    await auction.init();

    let res = (await auction.registerAsset(ledger1Principal, 1_000n) as any).Ok;
    expect(res).toEqual(1n); // 0n is trusted asset id
    res = (await auction.registerAsset(ledger2Principal, 1_000n) as any).Ok;
    expect(res).toEqual(2n);

    auction.setIdentity(user);

    await startNewAuctionSession();
  });

  afterEach(async () => {
    await pic.tearDown();
  });

  describe('canister installation', () => {
    test('should fail on first installation without arguments', async () => {
      const p = await pic.createCanister({
        sender: controller.getPrincipal(),
      });
      await expect(pic.installCode({
        canisterId: p,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], []]),
        sender: controller.getPrincipal(),
      })).rejects.toThrow(`Canister ${p.toText()} trapped explicitly: Trusted ledger principal not provided`);
    });

    test('should expose ledger principals', async () => {
      expect((await auction.getTrustedLedger()).toText()).toBe(trustedLedgerPrincipal.toText());
      let ledgers = await auction.icrcX_supported_tokens();
      expect(ledgers[0].toText()).toBe(trustedLedgerPrincipal.toText());
      expect(ledgers[1].toText()).toBe(ledger1Principal.toText());
    });

    test('should upgrade canister without arguments', async () => {
      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], []]),
        sender: controller.getPrincipal(),
      });
      await auction.init();
      expect((await auction.getTrustedLedger()).toText()).toBe(trustedLedgerPrincipal.toText());
      let ledgers = await auction.icrcX_supported_tokens();
      expect(ledgers[0].toText()).toBe(trustedLedgerPrincipal.toText());
      expect(ledgers[1].toText()).toBe(ledger1Principal.toText());
    });

    test('should be automatically initialized after upgrade', async () => {
      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], []]),
        sender: controller.getPrincipal(),
      });
      await auction.init();
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(0n);
    });

    test('should ignore arguments on upgrade', async () => {
      const fakeLedger = createIdentity('fakeLedger');
      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[fakeLedger.getPrincipal()], []]),
        sender: controller.getPrincipal(),
      });
      expect((await auction.getTrustedLedger()).toText()).toBe(trustedLedgerPrincipal.toText());
    });

    test('should preserve info during upgrade', async () => {
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 100n, 100_000]]);
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 100_000]]);

      await startNewAuctionSession();

      // check info before upgrade
      auction.setIdentity(user);
      expect(await auction.sessionsCounter()).toEqual(3n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(340_000_000n); // 500m - 150m paid - 10m locked
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.queryTokenBids(ledger2Principal)).toHaveLength(1);
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_amount{canister="${shortP}",asset_id="2"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="2"} 100 `);

      await pic.upgradeCanister({
        canisterId: auctionPrincipal,
        wasm: resolve(__dirname, '../.dfx/local/canisters/icrc1_auction/icrc1_auction.wasm'),
        arg: IDL.encode(aInit({ IDL }), [[], []]),
        sender: controller.getPrincipal(),
      });
      await auction.init();

      // check info after upgrade
      expect(await auction.sessionsCounter()).toEqual(3n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(340_000_000n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.queryTokenBids(ledger2Principal)).toHaveLength(1);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_amount{canister="${shortP}",asset_id="2"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="2"} 100 `);
    });
  });

  describe('timer', () => {
    test('should return remaining session time', async () => {
      expect(await auction.sessionRemainingTime()).toBe(36143n); // 10h (36000) + 2 minutes (120) + 23 seconds
      await pic.advanceTime(1143_000);
      await pic.tick();
      expect(await auction.sessionRemainingTime()).toBe(35000n);
    });
    test('should conduct new session after 24h', async () => {
      expect(await auction.sessionsCounter()).toBe(1n);
      await startNewAuctionSession();
      expect(await auction.sessionsCounter()).toBe(2n);
      await startNewAuctionSession();
      await startNewAuctionSession();
      expect(await auction.sessionsCounter()).toBe(4n);
    });
  });

  describe('deposit', () => {
    test('should be able to query deposit when not registered', async () => {
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(0n);
    });

    test('should accept deposit on notify', async () => {
      await mintDeposit(user, 10_000);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(0n);
      await auction.icrcX_notify({ token: trustedLedgerPrincipal });
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(10_000n);
    });

    test('should return total deposit', async () => {
      await mintDeposit(user, 10_000);
      await trustedLedger.issueTokens({
        owner: auctionPrincipal,
        subaccount: await auction.principalToSubaccount(user.getPrincipal()),
      }, BigInt(5_000));
      const ret = await auction.icrcX_notify({ token: trustedLedgerPrincipal });
      expect(ret).toEqual({
        Ok: {
          credit_inc: 15000n,
          deposit_inc: 15000n,
        },
      });
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(15_000n);
    });

    test('should return error if not enough balance', async () => {
      const ret = await auction.icrcX_notify({ token: trustedLedgerPrincipal });
      expect(ret).toEqual({Err: {NotAvailable: "Deposit was not detected"}});
    });

    test('should return error if wrong asset id', async () => {
      const ret = await auction.icrcX_notify({ token: createIdentity('fakeFt').getPrincipal() });
      expect(ret).toEqual({ Err: { NotAvailable: 'Unknown token' } });
    });

    test('should be able to withdraw deposit', async () => {
      await mintDeposit(user, 999, trustedLedgerPrincipal);
      await auction.icrcX_notify({ token: trustedLedgerPrincipal });
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(999n);
      expect(await trustedLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(0n);

      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 499n,
        token: trustedLedgerPrincipal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(500n);
      expect(await trustedLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(499n);
    });

    test('withdraw deposit should return insufficient deposit error', async () => {
      await prepareDeposit(user);
      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 500_000_001n,
        token: trustedLedgerPrincipal,
      });
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(500_000_000n);
    });
  });

  describe('bids', () => {

    const assertBidFulfilled = async (identity: Identity, ledger: Principal) => {
      auction.setIdentity(identity);
      expect(await auction.queryTokenBids(ledger)).toHaveLength(0); // bid is gone
      expect(await auction.icrcX_credit(ledger)).toBeGreaterThan(0n);
    };
    const assertBidNotFulfilled = async (identity: Identity, ledger: Principal) => {
      auction.setIdentity(identity);
      expect(await auction.queryTokenBids(ledger)).toHaveLength(1); // bid is still there
      expect(await auction.icrcX_credit(ledger)).toEqual(0n);
    };

    test('should not be able to place bid on non-existent token', async () => {
      await prepareDeposit(user);
      const ft = createIdentity('fakeFt').getPrincipal();
      const [res] = await auction.placeBids([[ft, 2_000n, 100_000]]);
      expect(res).toEqual({ Err: { UnknownAsset: null } });
      expect(await auction.queryTokenBids(ft)).toHaveLength(0);
    });

    test('should not be able to place bid on trusted token', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[trustedLedgerPrincipal, 2_000n, 100_000]]);
      expect(res).toEqual({ Err: { UnknownAsset: null } });
      expect(await auction.queryTokenBids(trustedLedgerPrincipal)).toHaveLength(0);
    });

    test('should not be able to place bid with non-sufficient deposit', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 2_000n, 1_000_000]]);
      expect(res).toEqual({ Err: { NoCredit: null } });
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
    });

    test('should not be able to place bid with too low volume', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 20n, 10_000]]);
      expect(res).toEqual({ Err: { TooLowOrder: null } });
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
    });

    test('should be able to place a bid', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 2_000n, 1_000]]);
      expect(res).toHaveProperty('Ok');
      const bids = await auction.queryTokenBids(ledger1Principal);
      expect(bids).toHaveLength(1);
      expect(bids[0][1]!.icrc1Ledger.toText()).toBe(ledger1Principal.toText());
      expect(bids[0][1]!.price).toBe(1_000);
      expect(bids[0][1]!.volume).toBe(2_000n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(498_000_000n); // available deposit went down
    });

    test('should affect metrics', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 2_000n, 15_000]]);
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_amount{canister="${shortP}",asset_id="1"} 1 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="1"} 2000 `);

      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 200_000_000n, 15_000]]);
      auction.setIdentity(user);
      await startNewAuctionSession();

      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_amount{canister="${shortP}",asset_id="1"} 0 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="1"} 0 `);
    });

    test('unfulfilled bids should affect deposit', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 1_000n, 400_000]]);
      expect(res).toHaveProperty('Ok');
      const [res2] = await auction.placeBids([[ledger2Principal, 1_000n, 400_000]]);
      expect(res2).toEqual({ Err: { NoCredit: null } });
    });

    test('should be able to place few bids on the same token', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(500_000_000n);
      await auction.placeBids([[ledger1Principal, 2_000n, 100_000]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);

      let [res] = await auction.placeBids([[ledger1Principal, 2_000n, 150_000]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(0n);

      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(2);
    });

    test('should not be able to place few bids on the same token with the same price', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(500_000_000n);
      let [res1] = await auction.placeBids([[ledger1Principal, 2_000n, 100_000]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);

      let [res2] = await auction.placeBids([[ledger1Principal, 2_000n, 100_000]]);
      expect(res2).toEqual({
        Err: {
          ConflictingOrder: [{ bid: null }, (res1 as any).Ok],
        },
      });

      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);
      expect(await auction.queryBids()).toHaveLength(1);
    });

    test('should be able to replace a bid', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(500_000_000n);
      let orderId = (await auction.placeBids([[ledger1Principal, 2_000n, 125_000]]) as any)[0].Ok;
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(250_000_000n);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);

      let res = await auction.replaceBid(orderId, 2_000n, 250_000);
      expect(res).toHaveProperty('Ok');
      orderId = (res as any).Ok;
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(0n);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);

      res = await auction.replaceBid(orderId, 2_000n, 60_000);
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(380_000_000n);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
    });

    test('non-sufficient deposit should not cancel old bid when replacing', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const orderId = (await auction.placeBids([[ledger1Principal, 2_000n, 125_000]]) as any)[0].Ok;

      let res = await auction.replaceBid(orderId, 2_000_000n, 250_000_000);
      expect(res).toEqual({ Err: { NoCredit: null } });

      let bids = await auction.queryTokenBids(ledger1Principal);
      expect(bids).toHaveLength(1);
      expect(bids[0][0]).toBe(orderId);
      expect(bids[0][1]!.icrc1Ledger.toText()).toBe(ledger1Principal.toText());
      expect(bids[0][1]!.price).toBe(125_000);
      expect(bids[0][1]!.volume).toBe(2_000n);
    });

    test('should fulfil the only bid', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 2_000n, 15_000]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);

      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 200_000_000n, 15_000]]);
      auction.setIdentity(user);
      await startNewAuctionSession();

      // test that bid disappeared
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
      // test that tokens were decremented from deposit, credit added
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(470_000_000n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(2_000n);
      // check history
      const historyItem = (await auction.queryTransactionHistory([], 1n, 0n))[0];
      expect(historyItem[1]).toEqual(2n);
      expect(historyItem[2]).toEqual({bid: null});
      expect(historyItem[3]).toEqual(ledger1Principal);
      expect(historyItem[4]).toEqual(2_000n);
      expect(historyItem[5]).toEqual(15_000);
    });

    test('should fulfil many bids at once', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await prepareDeposit(seller, ledger2Principal);
      await auction.placeAsks([[ledger1Principal, 200_000_000n, 100_000]]);
      await auction.placeAsks([[ledger2Principal, 200_000_000n, 100_000]]);
      auction.setIdentity(user);
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 1_500n, 100_000]]);

      const user2 = createIdentity('user2');
      await prepareDeposit(user2);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 1_500n, 100_000]]);

      await startNewAuctionSession();
      await assertBidFulfilled(user, ledger1Principal);
      await assertBidFulfilled(user, ledger2Principal);
      await assertBidFulfilled(user2, ledger1Principal);
      await assertBidFulfilled(user2, ledger2Principal);
    });

    test('should fulfil bids with the same price in order of insertion', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 2_000n, 0]]);
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);

      const user2 = createIdentity('user2');
      await prepareDeposit(user2);
      await auction.placeBids([[ledger1Principal, 999n, 100_000]]);

      const user3 = createIdentity('user3');
      await prepareDeposit(user3);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);

      await startNewAuctionSession();
      await assertBidFulfilled(user, ledger1Principal);
      await assertBidFulfilled(user2, ledger1Principal);

      auction.setIdentity(user3);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1n);
    });

    test('should charge lowest price', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 3_000n, 0]]);
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_500n, 200_000]]);

      const user2 = createIdentity('user2');
      await prepareDeposit(user2);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);

      // should be ignored (no supply)
      const user3 = createIdentity('user3');
      await prepareDeposit(user3);
      await auction.placeBids([[ledger1Principal, 1_500n, 50_000]]);

      await startNewAuctionSession();
      // check that price was 100 (lowest fulfilled bid) for both user and user2
      auction.setIdentity(user);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n);
      auction.setIdentity(user2);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n);
    });

    test('should fulfil lowest bid partially', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 3_500n, 0]]);
      await startNewAuctionSession();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_500n, 200_000]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(200_000_000n);

      const user2 = createIdentity('user2');
      await prepareDeposit(user2);
      await auction.placeBids([[ledger1Principal, 1_500n, 150_000]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(275_000_000n);

      const user3 = createIdentity('user3');
      await prepareDeposit(user3);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n);

      // should be ignored (no supply)
      const user4 = createIdentity('user4');
      await prepareDeposit(user4);
      await auction.placeBids([[ledger1Principal, 1_500n, 50_000]]);

      await startNewAuctionSession();
      // check that price was 100 (lowest partially fulfilled bid). Queried deposit grew for high bidders
      auction.setIdentity(user);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n);
      auction.setIdentity(user2);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_500n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n);
      // user whose bid was fulfilled partially
      auction.setIdentity(user3);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(500n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(350_000_000n); // 100m is locked in the bid, 50m were charged
      // check bid. Volume should be lowered by 500
      const bids = await auction.queryTokenBids(ledger1Principal);
      expect(bids).toHaveLength(1);
      expect(bids[0][1]!.icrc1Ledger.toText()).toBe(ledger1Principal.toText());
      expect(bids[0][1]!.price).toBe(100_000);
      expect(bids[0][1]!.volume).toBe(1_000n);
      // check that partial bid recorded in history
      const historyItem = (await auction.queryTransactionHistory([], 1n, 0n))[0];
      expect(historyItem[1]).toEqual(2n);
      expect(historyItem[2]).toEqual({bid: null});
      expect(historyItem[3]).toEqual(ledger1Principal);
      expect(historyItem[4]).toEqual(500n);
      expect(historyItem[5]).toEqual(100_000);
    });

    test('should carry partially fulfilled bid over to the next session', async () => {
      await prepareDeposit(user);
      const [res] = await auction.placeBids([[ledger1Principal, 2_000n, 100_000]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
      // add ask later, auction session already launched
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_000n, 0]]);
      auction.setIdentity(user);
      await startNewAuctionSession();
      // bid is still there
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_000n); // was partially fulfilled
      // add another ask
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_000n, 0]]);
      auction.setIdentity(user);
      await startNewAuctionSession();
      // bid should be fully fulfilled now
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(2_000n);
    });

    test('should fulfil bids by priority and preserve priority between bids through sessions', async () => {
      // ask enough only for one bid
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);

      await startNewAuctionSession();
      const mediumBidder = createIdentity('mediumBidder');
      await prepareDeposit(mediumBidder);
      await auction.placeBids([[ledger1Principal, 1_500n, 20_000]]);
      const highBidder = createIdentity('highBidder');
      await prepareDeposit(highBidder);
      await auction.placeBids([[ledger1Principal, 1_500n, 50_000]]);
      const lowBidder = createIdentity('lowBidder');
      await prepareDeposit(lowBidder);
      await auction.placeBids([[ledger1Principal, 1_500n, 5_000]]);

      // allow one additional bid next session
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_500n, 0]]);

      await startNewAuctionSession();
      await assertBidFulfilled(highBidder, ledger1Principal);
      await assertBidNotFulfilled(mediumBidder, ledger1Principal);
      await assertBidNotFulfilled(lowBidder, ledger1Principal);

      // allow one additional bid next session
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_500n, 0]]);

      await startNewAuctionSession();
      await assertBidFulfilled(mediumBidder, ledger1Principal);
      await assertBidNotFulfilled(lowBidder, ledger1Principal);

      const newBidder = createIdentity('newBidder');
      await prepareDeposit(newBidder);
      await auction.placeBids([[ledger1Principal, 1_500n, 20_000]]);

      // allow one additional bid next session
      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_500n, 0]]);

      await startNewAuctionSession();
      // new bidder joined later, but should be fulfilled since priority greater than priority of low bid
      await assertBidFulfilled(newBidder, ledger1Principal);
      await assertBidNotFulfilled(lowBidder, ledger1Principal);

      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_500n, 0]]);

      await startNewAuctionSession();
      // finally low bid will be fulfilled
      await assertBidFulfilled(lowBidder, ledger1Principal);
    });

    test('should be able to place another bid for next auction session', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_000n, 0]]);

      await startNewAuctionSession();
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);

      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_000n, 0]]);
      await startNewAuctionSession();

      await assertBidFulfilled(user, ledger1Principal);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1_000n);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);

      auction.setIdentity(seller);
      await auction.placeAsks([[ledger1Principal, 1_000n, 0]]);
      await startNewAuctionSession();
      await assertBidFulfilled(user, ledger1Principal);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(2_000n); // credit builds up
    });

  });

  describe('asks', () => {

    const assertAskFulfilled = async (identity: Identity, ledger: Principal) => {
      auction.setIdentity(identity);
      const a = await auction.queryTokenAsks(ledger);
      expect(await auction.queryTokenAsks(ledger)).toHaveLength(0); // ask is gone
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toBeGreaterThan(0n);
    };
    const assertAskNotFulfilled = async (identity: Identity, ledger: Principal, expectedTrustedCredit: number = 0) => {
      auction.setIdentity(identity);
      expect(await auction.queryTokenAsks(ledger)).toHaveLength(1); // ask is still there
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(BigInt(expectedTrustedCredit));
    };

    test('should not be able to place ask on non-existent token', async () => {
      await prepareDeposit(user);
      const ft = createIdentity('fakeFt').getPrincipal();
      const [res] = await auction.placeAsks([[ft, 2_000n, 100_000]]);
      expect(res).toEqual({ Err: { UnknownAsset: null } });
      expect(await auction.queryTokenAsks(ft)).toHaveLength(0);
    });

    test('should not be able to place ask on trusted token', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      const [res] = await auction.placeAsks([[trustedLedgerPrincipal, 2_000n, 100_000]]);
      expect(res).toEqual({ Err: { UnknownAsset: null } });
      expect(await auction.queryTokenAsks(trustedLedgerPrincipal)).toHaveLength(0);
    });

    test('should not be able to place ask with non-sufficient deposit', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const [res] = await auction.placeAsks([[ledger1Principal, 500_000_001n, 0]]);
      expect(res).toEqual({ Err: { NoCredit: null } });
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
    });

    test('should not be able to place an ask with too low volume', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const [res] = await auction.placeAsks([[ledger1Principal, 20n, 1]]);
      expect(res).toEqual({ Err: { TooLowOrder: null } });
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(0);
    });

    test('should be able to place a market ask', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const [res] = await auction.placeAsks([[ledger1Principal, 20n, 0]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);
    });

    test('should be able to place an ask', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const [res] = await auction.placeAsks([[ledger1Principal, 2_000_000n, 10]]);
      expect(res).toHaveProperty('Ok');
      const asks = await auction.queryTokenAsks(ledger1Principal);
      expect(asks).toHaveLength(1);
      expect(asks[0][1]!.icrc1Ledger.toText()).toBe(ledger1Principal.toText());
      expect(asks[0][1]!.price).toBe(10);
      expect(asks[0][1]!.volume).toBe(2_000_000n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(498_000_000n); // available deposit went down
    });

    test('should affect metrics', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);

      const buyer = createIdentity('buyer');
      await prepareDeposit(buyer);
      auction.setIdentity(buyer);
      await auction.placeBids([[ledger1Principal, 2_000_000n, 100]]);

      auction.setIdentity(user);
      await auction.placeAsks([[ledger1Principal, 2_000_000n, 100]]);
      const shortP = auctionPrincipal.toText().substring(0, auctionPrincipal.toString().indexOf('-'));
      let metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`asks_amount{canister="${shortP}",asset_id="1"} 1 `);
      expect(metrics).toContain(`asks_volume{canister="${shortP}",asset_id="1"} 2000000 `);

      await startNewAuctionSession();

      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`asks_amount{canister="${shortP}",asset_id="1"} 0 `);
      expect(metrics).toContain(`asks_volume{canister="${shortP}",asset_id="1"} 0 `);
    });

    test('should be able to place few asks on the same token', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(500_000_000n);
      await auction.placeAsks([[ledger1Principal, 125_000_000n, 125_000]]);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(375_000_000n);

      let [res] = await auction.placeAsks([[ledger1Principal, 175_000_000n, 250_000]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(200_000_000n);

      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(2);
    });

    test('should not be able to place few asks on the same token with the same price', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(500_000_000n);
      let [res1] = await auction.placeAsks([[ledger1Principal, 125_000_000n, 125_000]]);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(375_000_000n);

      let [res2] = await auction.placeAsks([[ledger1Principal, 175_000_000n, 125_000]]);
      expect(res2).toEqual({
        Err: {
          ConflictingOrder: [{ ask: null }, (res1 as any).Ok],
        },
      });
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(375_000_000n);
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);
    });

    test('should be able to replace an ask', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(500_000_000n);
      let orderId = (await auction.placeAsks([[ledger1Principal, 125_000_000n, 125_000]]) as any)[0].Ok;
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(375_000_000n);
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);

      let res = await auction.replaceAsk(orderId, 500_000_000n, 250_000);
      expect(res).toHaveProperty('Ok');
      orderId = (res as any).Ok;
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(0n);
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);

      res = await auction.replaceAsk(orderId, 120_000_000n, 60_000);
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(380_000_000n);
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);
    });

    test('non-sufficient deposit should not cancel old ask', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const orderId = (await auction.placeAsks([[ledger1Principal, 125_000_000n, 125_000]]) as any)[0].Ok;

      let res = await auction.replaceAsk(orderId, 600_000_000n, 50_000);
      expect(res).toEqual({ Err: { NoCredit: null } });

      let asks = await auction.queryTokenAsks(ledger1Principal);
      expect(asks).toHaveLength(1);
      expect(asks[0][0]).toBe(orderId);
      expect(asks[0][1]!.icrc1Ledger.toText()).toBe(ledger1Principal.toText());
      expect(asks[0][1]!.price).toBe(125_000);
      expect(asks[0][1]!.volume).toBe(125_000_000n);
    });

    test('should fulfil the only ask', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user, ledger1Principal);
      const [res] = await auction.placeAsks([[ledger1Principal, 100_000_000n, 3]]);
      expect(res).toHaveProperty('Ok');
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);

      const buyer = createIdentity('buyer');
      await prepareDeposit(buyer);
      auction.setIdentity(buyer);
      await auction.placeBids([[ledger1Principal, 100_010_000n, 3]]); // buy all 100m + 10k fees from ledger ask

      await startNewAuctionSession();
      auction.setIdentity(user);
      // test that ask disappeared
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(0);
      // test that tokens were decremented from deposit, credit added
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(400_000_000n);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(300_000_000n);
    });

    test('should sell by price priority and preserve priority', async () => {
      const buyer = createIdentity('buyer');
      for (let i = 0; i < 10; i++) {
        await prepareDeposit(buyer);
      }
      await startNewAuctionSession();
      await auction.placeBids([[ledger1Principal, 1_500_000n, 500]]);
      expect(await auction.icrcX_credit(trustedLedgerPrincipal)).toEqual(BigInt(5_000_000_000 - 1_500_000 * 500));

      const mediumSeller = createIdentity('mediumSeller');
      await prepareDeposit(mediumSeller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 200]]);
      const highSeller = createIdentity('highSeller');
      await prepareDeposit(highSeller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 500]]);
      const lowSeller = createIdentity('lowSeller');
      await prepareDeposit(lowSeller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 50]]);

      const newSeller = createIdentity('newSeller');
      await prepareDeposit(newSeller, ledger1Principal);

      await startNewAuctionSession();
      auction.setIdentity(buyer);
      await assertAskFulfilled(lowSeller, ledger1Principal);
      await assertAskNotFulfilled(mediumSeller, ledger1Principal);
      await assertAskNotFulfilled(highSeller, ledger1Principal);
      // deal between buyer and lowSeller should have average price (500, 50 => 275)
      auction.setIdentity(lowSeller);
      expect(Number(await auction.icrcX_credit(trustedLedgerPrincipal)) / 1_500_000).toEqual(275);
      auction.setIdentity(buyer);
      expect((5_000_000_000 - Number(await auction.icrcX_credit(trustedLedgerPrincipal))) / 1_500_000).toEqual(275);

      auction.setIdentity(buyer);// allow one additional ask to be fulfilled
      await auction.placeBids([[ledger1Principal, 1_500_000n, 500]]);
      await startNewAuctionSession();
      await assertAskFulfilled(mediumSeller, ledger1Principal);
      await assertAskNotFulfilled(highSeller, ledger1Principal);
      auction.setIdentity(mediumSeller);
      expect(Number(await auction.icrcX_credit(trustedLedgerPrincipal)) / 1_500_000).toEqual(350);

      auction.setIdentity(newSeller);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 300]]);

      auction.setIdentity(buyer);// allow one additional ask to be fulfilled
      await auction.placeBids([[ledger1Principal, 1_500_000n, 500]]);
      await startNewAuctionSession();
      // new seller joined later, but should be fulfilled since priority greater than priority of high seller
      await assertAskFulfilled(newSeller, ledger1Principal);
      await assertAskNotFulfilled(highSeller, ledger1Principal);
      auction.setIdentity(newSeller);
      expect(Number(await auction.icrcX_credit(trustedLedgerPrincipal)) / 1_500_000).toEqual(400);

      auction.setIdentity(buyer);// allow one additional ask to be fulfilled
      await auction.placeBids([[ledger1Principal, 1_500_000n, 500]]);
      await startNewAuctionSession();
      // finally high ask will be fulfilled
      await assertAskFulfilled(highSeller, ledger1Principal);
      auction.setIdentity(highSeller);
      expect(Number(await auction.icrcX_credit(trustedLedgerPrincipal)) / 1_500_000).toEqual(500);
    });
  });

  describe('orders', () => {

    test('should be able to place both bid and ask on the same asset', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      await prepareDeposit(user, ledger1Principal);
      const [res1] = await auction.placeBids([[ledger1Principal, 2_000n, 250]]);
      expect(res1).toHaveProperty('Ok');
      const [res2] = await auction.placeAsks([[ledger1Principal, 2_000_000n, 300]]);
      expect(res2).toHaveProperty('Ok');
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
    });

    test('should return error when placing ask with lower price than own bid price for the same asset', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      await prepareDeposit(user, ledger1Principal);
      const [res1] = await auction.placeBids([[ledger1Principal, 2_000n, 250]]);
      expect(res1).toHaveProperty('Ok');
      const [res2] = await auction.placeAsks([[ledger1Principal, 2_000_000n, 200]]);
      expect(res2).toEqual({
        Err: {
          ConflictingOrder: [{ bid: null }, (res1 as any).Ok],
        }
      });
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(1);
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(0);
    });

    test('should return error when placing bid with higher price than own ask price for the same asset', async () => {
      await startNewAuctionSession();
      await prepareDeposit(user);
      await prepareDeposit(user, ledger1Principal);
      const [res1] = await auction.placeAsks([[ledger1Principal, 2_000_000n, 200]]);
      expect(res1).toHaveProperty('Ok');
      const [res2] = await auction.placeBids([[ledger1Principal, 2_000n, 250]]);
      expect(res2).toEqual({
        Err: {
          ConflictingOrder: [{ ask: null }, (res1 as any).Ok],
        }
      });
      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(1);
      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
    });

  })

  describe('history', () => {

    test('should return price history with descending order', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await prepareDeposit(seller, ledger2Principal);
      await auction.placeAsks([[ledger1Principal, 1_000n, 100_000]]);
      await auction.placeAsks([[ledger2Principal, 1_000n, 100_000]]);
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 1_000n, 100_000]]);
      await startNewAuctionSession();
      const history = await auction.queryPriceHistory([], 2n, 0n);
      expect(history[0][2].toText()).toBe(ledger2Principal.toText());
      expect(history[0][3]).toBe(1_000n);
      expect(history[0][4]).toBe(100_000);
      expect(history[1][2].toText()).toBe(ledger1Principal.toText());
      expect(history[1][3]).toBe(1_000n);
      expect(history[1][4]).toBe(100_000);
    });

    test('should order transaction history with descending order', async () => {
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await prepareDeposit(seller, ledger2Principal);
      await auction.placeAsks([[ledger1Principal, 1_000n, 100_000]]);
      await auction.placeAsks([[ledger2Principal, 1_000n, 100_000]]);
      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_000n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 1_000n, 100_000]]);
      await startNewAuctionSession();
      const history = await auction.queryTransactionHistory([], 2n, 0n);
      expect(history[0][3].toText()).toBe(ledger2Principal.toText());
      expect(history[1][3].toText()).toBe(ledger1Principal.toText());
    });
  });

  describe('credit', () => {

    test('should be able to query credit when not registered', async () => {
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(0n);
    });

    test('should return #InsufficientCredit if not registered', async () => {
      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 1_000n,
        token: ledger1Principal,
      });
      expect(res).toEqual({ Err: { InsufficientCredit: null } });
    });

    test('should return #InsufficientCredit if not enough credits', async () => {
      await prepareDeposit(user, ledger1Principal, 800);
      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 1_000n,
        token: ledger1Principal,
      });
      expect(res).toEqual({ Err: { InsufficientCredit: null } });
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(800n);
    });

    test('should withdraw credit successfully', async () => {
      await prepareDeposit(user, ledger1Principal, 1_200);
      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 1_200n,
        token: ledger1Principal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_200n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(0n);
    });

    test('should withdraw credit successfully with ICRC1 fee', async () => {
      await ledger1.updateFee(BigInt(3));
      await prepareDeposit(user, ledger1Principal, 1_200);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(1197n);
      const res = await auction.icrcX_withdraw({
        to_subaccount: [],
        amount: 1_197n,
        token: ledger1Principal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_194n);
      expect(await auction.icrcX_credit(ledger1Principal)).toEqual(0n);
    });
  });
});
