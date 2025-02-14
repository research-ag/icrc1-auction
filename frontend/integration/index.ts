import { useMutation, useQuery, useQueryClient } from 'react-query';
import { useSnackbar } from 'notistack';

import { useIdentity } from './identity';
import { Principal } from '@dfinity/principal';
import { useMemo } from 'react';
import { createActor } from '@declarations/icrc1_auction';
import { AuctionQueryResponse } from "@declarations/icrc1_auction/icrc1_auction_development.did";
import { createActor as createLedgerActor } from '@declarations/icrc1_ledger_mock';
import { CKBTC_MINTER_MAINNET_XPUBKEY, Minter } from "@research-ag/ckbtc-address-js";

// Custom replacer function for JSON.stringify
const bigIntReplacer = (key: string, value: any): any => {
  if (typeof value === 'bigint') {
    return `${value.toString()}n`; // Serialize BigInts as strings with 'n' suffix
  }
  return value;
};

const replaceBigInts = <T>(obj: T): T => {
  if (typeof obj === 'bigint') {
    return Number(obj) as any;
  } else if (Array.isArray(obj)) {
    return obj.map(replaceBigInts) as any;
  } else if (obj !== null && typeof obj === 'object' && !(obj instanceof Principal)) {
    return Object.fromEntries(
      Object.entries(obj).map(([key, value]) => [key, replaceBigInts(value)])
    ) as any;
  }
  return obj;
}

export const defaultAuctionCanisterId = "farwr-jqaaa-aaaao-qj4ya-cai";

let ckBtcMinter = new Minter(CKBTC_MINTER_MAINNET_XPUBKEY);

let userToSubaccount = (user: Principal): Uint8Array => {
  let arr = Array.from(user.toUint8Array());
  arr.unshift(arr.length);
  while (arr.length < 32) {
    arr.unshift(0);
  }
  return new Uint8Array(arr);
};

export const useAuctionCanisterId = () => {
  return localStorage.getItem('auctionCanisterId') || defaultAuctionCanisterId;
};

export const updateAuctionCanisterId = (ps: string) => {
  localStorage.setItem('auctionCanisterId', ps);
  const queryClient = useQueryClient();
  Promise.all([
    queryClient.invalidateQueries('admins'),
    queryClient.invalidateQueries('assets'),
    queryClient.invalidateQueries('assetInfos'),
    queryClient.invalidateQueries('deposit-history'),
    queryClient.invalidateQueries('auctionQuery'),
  ]).then();
};

export const useAuction = () => {
  const { identity } = useIdentity();
  const canisterId = useAuctionCanisterId();
  try {
    const auction = createActor(canisterId, {
      agentOptions: {
        identity,
        verifyQuerySignatures: false,
      },
    });
    return { auction };
  } catch (err) {
    const { enqueueSnackbar } = useSnackbar();
    enqueueSnackbar(`Auction ${canisterId} cannot be used. Falling back to ${defaultAuctionCanisterId}`, { variant: 'warning' });
    updateAuctionCanisterId(defaultAuctionCanisterId);
    const auction = createActor(defaultAuctionCanisterId, {
      agentOptions: {
        identity,
        verifyQuerySignatures: false,
      },
    });
    return { auction };
  }
};

export const useQuoteLedger = () => {
  const { auction } = useAuction();
  return useQuery(
    'quoteLedger',
    () => auction.getQuoteLedger(), {
      onError: () => {
        useQueryClient().removeQueries('quoteLedger');
      },
    });
};

export const useSessionsCounter = () => {
  const { auction } = useAuction();
  return useQuery(
    'sessionsCounter',
    () => auction.nextSession().then(({ counter }) => counter),
    {
      onError: () => {
        useQueryClient().removeQueries('sessionsCounter');
      },
    });
};

export const useMinimumOrder = () => {
  const { auction } = useAuction();
  return useQuery(
    'minimumOrder',
    () => auction.settings().then(({ orderQuoteVolumeMinimum }) => orderQuoteVolumeMinimum),
    {
      onError: () => {
        useQueryClient().removeQueries('minimumOrder');
      },
    },
  );
};

export const usePrincipalToSubaccount = (p: Principal) => {
  const { auction } = useAuction();
  return useQuery(
    'subaccount_' + p.toText(),
    async () => auction.principalToSubaccount(p),
    {
      onError: () => {
        useQueryClient().removeQueries('subaccount_' + p.toText());
      },
    },
  );
};

export const useAddAsset = () => {
  const { auction } = useAuction();

  const queryClient = useQueryClient();

  const { enqueueSnackbar } = useSnackbar();

  return useMutation(
    (formObj: { principal: Principal; minAskVolume: number }) =>
      auction.registerAsset(formObj.principal, BigInt(formObj.minAskVolume)),
    {
      onSuccess: (res, { principal, minAskVolume }) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to add ledger: ${JSON.stringify(res.Err, bigIntReplacer)}`, { variant: 'error' });
        } else {
          queryClient.invalidateQueries('assets');
          queryClient.invalidateQueries('assetInfos');
          enqueueSnackbar(`Ledger ${principal.toText()} added. Asset index: ${minAskVolume}`, { variant: 'success' });
        }
      },
      onError: () => {
        enqueueSnackbar('Failed to add ledger', { variant: 'error' });
      },
    },
  );
};

export const useListAssets = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  const queryClient = useQueryClient();

  return useQuery(
    'assets',
    async () => auction.icrc84_supported_tokens(),
    {
      onSettled: _ => queryClient.invalidateQueries('assetInfos'),
      onError: err => {
        enqueueSnackbar(`Failed to fetch credits: ${err}`, { variant: 'error' });
        queryClient.removeQueries('assets');
        queryClient.removeQueries('assetInfos');
      },
    },
  );
};

export const useTokenInfoMap = () => {
  useListAssets();
  const { enqueueSnackbar } = useSnackbar();
  const queryClient = useQueryClient();
  return useQuery(
    'assetInfos',
    async () => {
      const assets = queryClient.getQueryData('assets') as (Principal[] | undefined);
      const info = await Promise.all((assets || []).map(async p => createLedgerActor(p).icrc1_metadata()));
      const mapInfo = (info: ['icrc1:decimals' | 'icrc1:symbol', { 'Nat': bigint } | { 'Text': string }][]): {
        symbol: string,
        decimals: number
      } => {
        const ret = {
          symbol: '-',
          decimals: 0,
        };
        for (const [k, v] of info) {
          if (k === 'icrc1:decimals') {
            ret.decimals = Number((v as any).Nat as bigint);
          } else if (k === 'icrc1:symbol') {
            ret.symbol = (v as any).Text;
          }
        }
        return ret;
      };
      return (assets || []).map((p, i) => ([p, mapInfo(info[i] as any)])) as [Principal, {
        symbol: string,
        decimals: number
      }][];
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch asset info: ${err}`, { variant: 'error' });
        queryClient.removeQueries('assetInfos');
      },
    },
  );
};

export const useAuctionQuery = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'auctionQuery',
    async () => {
      return replaceBigInts(await auction.auction_query([], {
        asks: [true],
        bids: [true],
        credits: [true],
        session_numbers: [],
        deposit_history: [[BigInt(10000), BigInt(0)]],
        transaction_history: [[BigInt(10000), BigInt(0)]],
        price_history: []
      }));
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to query auction: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('auctionQuery');
      },
    },
  );
};

export const useListOrders = (auctionQueryData: AuctionQueryResponse | undefined, kind: 'ask' | 'bid') => {
  return useQuery(
    [kind === 'bid' ? 'myBids' : 'myAsks', auctionQueryData],
    async () => (kind === 'ask' ? auctionQueryData?.asks : auctionQueryData?.bids) || [],
    { enabled: !!auctionQueryData }
  );
};

export const useListCredits = (auctionQueryData: AuctionQueryResponse | undefined) => {
  return useQuery(
    ['myCredits', auctionQueryData],
    async () => auctionQueryData?.credits || [],
    { enabled: !!auctionQueryData }
  );
};

export const usePoints = (auctionQueryData: AuctionQueryResponse | undefined) => {
  return useQuery(
    ['myPoints', auctionQueryData],
    async () => auctionQueryData?.points || 0,
    { enabled: !!auctionQueryData }
  );
};

export const useNotify = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation((icrc1Ledger: Principal) => auction.icrc84_notify({ token: icrc1Ledger }), {
    onSuccess: res => {
      if ('Err' in res) {
        enqueueSnackbar(`Failed to deposit: ${JSON.stringify(res.Err, bigIntReplacer)}`, { variant: 'error' });
      } else {
        queryClient.invalidateQueries('auctionQuery');
        queryClient.invalidateQueries('deposit-history');
        enqueueSnackbar(`Deposited ${Number(res.Ok.credit_inc)} tokens successfully`, { variant: 'success' });
      }
    },
    onError: err => {
      enqueueSnackbar(`Failed to deposit: ${err}`, { variant: 'error' });
    },
  });
};

export const useBtcAddress = (p: Principal) => {
  const { auction } = useAuction();
  const canisterId = useAuctionCanisterId();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'btc_addrr_' + p.toText(),
    async () => {
      return ckBtcMinter.depositAddr({
        owner: canisterId,
        subaccount: userToSubaccount(p),
      });
    },
    {
      onError: (err) => {
        useQueryClient().removeQueries('btc_addrr_' + p.toText());
        enqueueSnackbar(`${err}`, { variant: 'error' });
      },
    }
  );
};

export const useBtcNotify = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(() => auction.btc_notify(), {
    onSuccess: res => {
      if ('Err' in res) {
        enqueueSnackbar(`Failed to deposit: ${JSON.stringify(res.Err, bigIntReplacer)}`, { variant: 'error' });
      } else {
        queryClient.invalidateQueries('myCredits');
        queryClient.invalidateQueries('deposit-history');
        enqueueSnackbar(`Deposited ${Number(res.Ok.credit_inc)} tokens successfully`, { variant: 'success' });
      }
    },
    onError: err => {
      enqueueSnackbar(`Failed to deposit: ${err}`, { variant: 'error' });
    },
  });
};

export const useDeposit = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(
    (arg: { token: Principal; amount: number; owner: Principal, subaccount: Uint8Array | number[] | null }) =>
      auction.icrc84_deposit({
        token: arg.token,
        amount: BigInt(arg.amount),
        from: {
          owner: arg.owner,
          subaccount: arg.subaccount ? [arg.subaccount] : [],
        },
        expected_fee: [],
      }),
    {
      onSuccess: res => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to deposit: ${JSON.stringify(res.Err, bigIntReplacer)}`, { variant: 'error' });
        } else {
          queryClient.invalidateQueries('auctionQuery');
          enqueueSnackbar(`Deposited ${Number(res.Ok.credit_inc)} tokens successfully`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to deposit: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const usePlaceOrder = (kind: 'ask' | 'bid') => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(
    (formObj: { ledger: string; volume: number; price: number }) =>
      (kind === 'bid' ? auction.placeBids : auction.placeAsks).bind(auction)(
        [[Principal.fromText(formObj.ledger), BigInt(formObj.volume), Number(formObj.price)]],
        [],
      ),
    {
      onSuccess: ([res]) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to place a ${kind}: ${JSON.stringify(res.Err, bigIntReplacer)}`, {
            variant: 'error',
          });
        } else {
          queryClient.invalidateQueries('auctionQuery');
          enqueueSnackbar(`${kind} placed`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to place a ${kind}: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useCancelOrder = (kind: 'ask' | 'bid') => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(
    (orderId: bigint) => (kind === 'bid' ? auction.cancelBids([orderId], []) : auction.cancelAsks([orderId], [])),
    {
      onSuccess: ([res]) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to cancel the ${kind}: ${JSON.stringify(res.Err, bigIntReplacer)}`, {
            variant: 'error',
          });
        } else {
          queryClient.invalidateQueries('auctionQuery');
          enqueueSnackbar(`${kind} cancelled`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to cancel the ${kind}: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useDepositHistory = (auctionQueryData: AuctionQueryResponse | undefined) => {
  return useQuery(
    ['deposit-history', auctionQueryData],
    async () => auctionQueryData?.deposit_history || [],
    { enabled: !!auctionQueryData }
  );
};

export const useTransactionHistory = (auctionQueryData: AuctionQueryResponse | undefined) => {
  return useQuery(
    ['transaction-history', auctionQueryData],
    async () => auctionQueryData?.transaction_history || [],
    { enabled: !!auctionQueryData }
  );
};

export const usePriceHistory = (limit: number, offset: number) => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();

  return useQuery(
    ['price-history', offset],
    async () => {
      const res = await auction.auction_query([], {
        asks: [],
        bids: [],
        credits: [],
        session_numbers: [],
        deposit_history: [],
        transaction_history: [],
        price_history: [[BigInt(limit), BigInt(offset), false]]
      });
      return res.price_history;
    },
    {
      keepPreviousData: true,
      onError: err => {
        enqueueSnackbar(`Failed to fetch price history: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('price-history');
      },
    },
  );
};

export const useWithdrawBtc = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  const { identity } = useIdentity();
  return useMutation(
    (formObj: { address: string; amount: number }) =>
      auction.btc_withdraw({
        to: formObj.address,
        amount: BigInt(formObj.amount),
      }),
    {
      onSuccess: res => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to withdraw BTC: ${JSON.stringify(res.Err, bigIntReplacer)}`, {
            variant: 'error',
          });
        } else if ('Ok' in res) {
          queryClient.invalidateQueries('myCredits');
          queryClient.invalidateQueries('deposit-history');
          enqueueSnackbar(`BTC withdraw request sent. Block index: ${res['Ok'].block_index}`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to withdraw credit: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useWithdrawCredit = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  const { identity } = useIdentity();
  return useMutation(
    (formObj: { ledger: string; amount: number; owner?: string; subaccount: Uint8Array | null }) =>
      auction.icrc84_withdraw({
        token: Principal.fromText(formObj.ledger),
        to: {
          owner: formObj.owner ? Principal.fromText(formObj.owner) : identity.getPrincipal(),
          subaccount: formObj.subaccount ? [formObj.subaccount] : []
        },
        amount: BigInt(formObj.amount),
        expected_fee: [],
      }),
    {
      onSuccess: res => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to withdraw credit: ${JSON.stringify(res.Err, bigIntReplacer)}`, {
            variant: 'error',
          });
        } else {
          queryClient.invalidateQueries('auctionQuery');
          queryClient.invalidateQueries('deposit-history');
          enqueueSnackbar(`Credit withdrawn successfully`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to withdraw credit: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useGetAdmins = () => {
  const { auction } = useAuction();

  const { enqueueSnackbar } = useSnackbar();

  return useQuery('admins', () => auction.listAdmins(), {
    onError: () => {
      enqueueSnackbar('Failed to fetch owners', { variant: 'error' });
      useQueryClient().removeQueries('admins');
    },
  });
};

export const useAddAdmin = () => {
  const { auction } = useAuction();

  const queryClient = useQueryClient();

  const { enqueueSnackbar } = useSnackbar();

  return useMutation((p: Principal) => auction.addAdmin(p), {
    onSuccess: (_, principal) => {
      queryClient.invalidateQueries('admins');
      enqueueSnackbar(`Principal ${principal} added`, { variant: 'success' });
    },
    onError: () => {
      enqueueSnackbar('Failed to add admin', { variant: 'error' });
    },
  });
};

export const useRemoveAdmin = () => {
  const { auction } = useAuction();

  const queryClient = useQueryClient();

  const { enqueueSnackbar } = useSnackbar();

  return useMutation((p: Principal) => auction.removeAdmin(p), {
    onSuccess: (_, principal) => {
      queryClient.invalidateQueries('admins');
      enqueueSnackbar(`Principal ${principal} removed`, { variant: 'success' });
    },
    onError: err => {
      enqueueSnackbar(`${err}`, { variant: 'error' });
    },
  });
};

export const useIsAdmin = () => {
  const { data } = useGetAdmins();
  const { identity } = useIdentity();
  return useMemo(
    () => (data ?? []).some(principal => principal.toText() === identity.getPrincipal().toText()),
    [data, identity],
  );
};
