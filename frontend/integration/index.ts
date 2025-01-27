import { useMutation, useQuery, useQueryClient } from 'react-query';
import { useSnackbar } from 'notistack';

import { useIdentity } from './identity';
import { Principal } from '@dfinity/principal';
import { useMemo } from 'react';
import { createActor } from '@declarations/icrc1_auction_continous';
import { createActor as createLedgerActor } from '@declarations/icrc1_ledger_mock';

// Custom replacer function for JSON.stringify
const bigIntReplacer = (key: string, value: any): any => {
  if (typeof value === 'bigint') {
    return `${value.toString()}n`; // Serialize BigInts as strings with 'n' suffix
  }
  return value;
};

export const defaultAuctionCanisterId = "kkmxt-jqaaa-aaaap-anwoq-cai";

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
    queryClient.invalidateQueries('myCredits'),
    queryClient.invalidateQueries('deposit-history'),
    queryClient.invalidateQueries('myBids'),
    queryClient.invalidateQueries('myAsks'),
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

export const useListOrders = (kind: 'ask' | 'bid') => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    kind === 'bid' ? 'myBids' : 'myAsks',
    async () => {
      const [res, accountRev] = await (kind === 'bid' ? auction.queryBids() : auction.queryAsks());
      return res;
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch ${kind}s: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('bid' ? 'myBids' : 'myAsks');
      },
    },
  );
};

export const useListCredits = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'myCredits',
    async () => {
      const [res, accountRev] = await auction.queryCredits();
      return res;
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch credits: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('myCredits');
      },
    },
  );
};

export const usePoints = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'points',
    async () => {
      return auction.queryPoints();
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch points: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('points');
      },
    },
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
          queryClient.invalidateQueries('myCredits');
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
    (formObj: { ledger: string; volume: number; price: number; orderBookType: 'delayed' | 'immediate' }) =>
      (kind === 'bid' ? auction.placeBids : auction.placeAsks).bind(auction)(
        [[Principal.fromText(formObj.ledger), { [formObj.orderBookType]: null } as any, BigInt(formObj.volume), Number(formObj.price)]],
        [],
      ),
    {
      onSuccess: ([res]) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to place a ${kind}: ${JSON.stringify(res.Err, bigIntReplacer)}`, {
            variant: 'error',
          });
        } else if ('Ok' in res) {
          queryClient.invalidateQueries(kind === 'bid' ? 'myBids' : 'myAsks');
          let orderId = res['Ok'][0];
          if ('placed' in res['Ok'][1]) {
            enqueueSnackbar(`${kind} placed, order ID: ${orderId}`, { variant: 'success' });
          } else if ('executed' in res['Ok'][1]) {
            let [price, volumeExecuted] = res['Ok'][1]['executed'];
            enqueueSnackbar(`${kind} executed with price ${price}, volume executed: ${volumeExecuted}`, { variant: 'success' });
          }
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
          queryClient.invalidateQueries(kind === 'bid' ? 'myBids' : 'myAsks');
          enqueueSnackbar(`${kind} cancelled`, { variant: 'success' });
        }
      },
      onError: err => {
        enqueueSnackbar(`Failed to cancel the ${kind}: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useDepositHistory = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'deposit-history',
    async () => {
      return auction.queryDepositHistory([], BigInt(10000), BigInt(0));
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch deposit history: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('deposit-history');
      },
    },
  );
};

export const useTransactionHistory = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'transaction-history',
    async () => {
      return auction.queryTransactionHistory([], BigInt(10000), BigInt(0));
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch transaction history: ${err}`, { variant: 'error' });
        useQueryClient().removeQueries('transaction-history');
      },
    },
  );
};

export const usePriceHistory = (limit: number, offset: number) => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();

  return useQuery(
    ['price-history', offset],
    async () => {
      return auction.queryPriceHistory([], BigInt(limit), BigInt(offset), false);
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

export const useWithdrawCredit = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  const { identity } = useIdentity();
  return useMutation(
    (formObj: { ledger: string; amount: number; subaccount: Uint8Array | null }) =>
      auction.icrc84_withdraw({
        token: Principal.fromText(formObj.ledger),
        to: { owner: identity.getPrincipal(), subaccount: formObj.subaccount ? [formObj.subaccount] : [] },
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
          queryClient.invalidateQueries('myCredits');
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
