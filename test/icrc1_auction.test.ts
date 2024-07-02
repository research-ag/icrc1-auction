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
    await auction.icrc84_notify({ token });
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

    await auction.runAuctionImmediately();
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
      let ledgers = await auction.icrc84_supported_tokens();
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
      let ledgers = await auction.icrc84_supported_tokens();
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
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(0n);
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
      await auction.runAuctionImmediately();

      await prepareDeposit(user);
      await auction.placeBids([[ledger1Principal, 1_500n, 100_000]]);
      await auction.placeBids([[ledger2Principal, 100n, 100_000]]);
      const seller = createIdentity('seller');
      await prepareDeposit(seller, ledger1Principal);
      await auction.placeAsks([[ledger1Principal, 1_500_000n, 100_000]]);

      await auction.runAuctionImmediately();

      // check info before upgrade
      auction.setIdentity(user);
      expect(await auction.sessionsCounter()).toEqual(3n);
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(340_000_000n); // 500m - 150m paid - 10m locked
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(1_500n);
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
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(340_000_000n);
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(1_500n);
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
      expect(await auction.sessionRemainingTime()).toBe(79_343n); // 22h (79200) + 2 minutes (120) + 23 seconds
      await pic.advanceTime(4_343_000);
      await pic.tick();
      expect(await auction.sessionRemainingTime()).toBe(75_000n);
    });
    test('should conduct new session after 24h', async () => {
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
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(0n);
    });

    test('should accept deposit on notify', async () => {
      await mintDeposit(user, 10_000);
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(0n);
      await auction.icrc84_notify({ token: trustedLedgerPrincipal });
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(10_000n);
    });

    test('should return total deposit', async () => {
      await mintDeposit(user, 10_000);
      await trustedLedger.issueTokens({
        owner: auctionPrincipal,
        subaccount: await auction.principalToSubaccount(user.getPrincipal()),
      }, BigInt(5_000));
      const ret = await auction.icrc84_notify({ token: trustedLedgerPrincipal });
      expect(ret).toEqual({
        Ok: {
          credit: 15000n,
          credit_inc: 15000n,
          deposit_inc: 15000n,
        },
      });
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(15_000n);
    });

    test('should return error if not enough balance', async () => {
      const ret = await auction.icrc84_notify({ token: trustedLedgerPrincipal });
      expect(ret).toEqual({ Err: { NotAvailable: { message: 'Deposit was not detected' } } });
    });

    test('should return error if wrong asset id', async () => {
      const ret = await auction.icrc84_notify({ token: createIdentity('fakeFt').getPrincipal() });
      expect(ret).toEqual({ Err: { NotAvailable: { message: 'Unknown token' } } });
    });

    test('should be able to withdraw deposit', async () => {
      await mintDeposit(user, 999, trustedLedgerPrincipal);
      await auction.icrc84_notify({ token: trustedLedgerPrincipal });
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(999n);
      expect(await trustedLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(0n);

      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 499n,
        token: trustedLedgerPrincipal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(500n);
      expect(await trustedLedger.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(499n);
    });

    test('withdraw deposit should return insufficient deposit error', async () => {
      await prepareDeposit(user);
      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 500_000_001n,
        token: trustedLedgerPrincipal,
      });
      expect(await auction.icrc84_credit(trustedLedgerPrincipal)).toEqual(500_000_000n);
    });
  });

  describe('bids', () => {

    test('should affect metrics', async () => {
      await auction.runAuctionImmediately();
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
      await auction.runAuctionImmediately();

      expect(await auction.queryTokenBids(ledger1Principal)).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`bids_amount{canister="${shortP}",asset_id="1"} 0 `);
      expect(metrics).toContain(`bids_volume{canister="${shortP}",asset_id="1"} 0 `);
    });

  });

  describe('asks', () => {

    test('should affect metrics', async () => {
      await auction.runAuctionImmediately();
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

      await auction.runAuctionImmediately();

      expect(await auction.queryTokenAsks(ledger1Principal)).toHaveLength(0);
      metrics = await auction
        .http_request({ method: 'GET', url: '/metrics?', body: new Uint8Array(), headers: [] })
        .then(r => new TextDecoder().decode(r.body as Uint8Array));
      expect(metrics).toContain(`asks_amount{canister="${shortP}",asset_id="1"} 0 `);
      expect(metrics).toContain(`asks_volume{canister="${shortP}",asset_id="1"} 0 `);
    });
  });

  describe('credit', () => {

    test('should be able to query credit when not registered', async () => {
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(0n);
    });

    test('should return #InsufficientCredit if not registered', async () => {
      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 1_000n,
        token: ledger1Principal,
      });
      expect(res).toEqual({ Err: { InsufficientCredit: {} } });
    });

    test('should return #InsufficientCredit if not enough credits', async () => {
      await prepareDeposit(user, ledger1Principal, 800);
      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 1_000n,
        token: ledger1Principal,
      });
      expect(res).toEqual({ Err: { InsufficientCredit: {} } });
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(800n);
    });

    test('should withdraw credit successfully', async () => {
      await prepareDeposit(user, ledger1Principal, 1_200);
      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 1_200n,
        token: ledger1Principal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_200n);
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(0n);
    });

    test('should withdraw credit successfully with ICRC1 fee', async () => {
      await ledger1.updateFee(BigInt(3));
      await prepareDeposit(user, ledger1Principal, 1_200);
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(1197n);
      const res = await auction.icrc84_withdraw({
        to_subaccount: [],
        amount: 1_197n,
        token: ledger1Principal,
      });
      expect(res).toHaveProperty('Ok');
      expect(await ledger1.icrc1_balance_of({ owner: user.getPrincipal(), subaccount: [] })).toEqual(1_194n);
      expect(await auction.icrc84_credit(ledger1Principal)).toEqual(0n);
    });
  });
});
