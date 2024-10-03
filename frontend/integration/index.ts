import { useMutation, useQuery, useQueryClient } from 'react-query';
import { useSnackbar } from 'notistack';

import { useIdentity } from './identity';
import { Principal } from '@dfinity/principal';
import { useMemo } from 'react';
import { canisterId as cid, createActor } from '@declarations/icrc1_auction';
import { createActor as createLedgerActor } from '@declarations/icrc1_ledger_mock';

// Custom replacer function for JSON.stringify
const bigIntReplacer = (key: string, value: any): any => {
  if (typeof value === 'bigint') {
    return `${value.toString()}n`; // Serialize BigInts as strings with 'n' suffix
  }
  return value;
};

export const canisterId = cid;

export const useAuction = () => {
  const { identity } = useIdentity();
  const auction = createActor(canisterId, {
    agentOptions: {
      identity,
      verifyQuerySignatures: false,
    },
  });
  return { auction };
};

export const useQuoteLedger = () => {
  const { auction } = useAuction();
  return useQuery('quoteLedger', () => auction.getQuoteLedger());
};

export const useSessionsCounter = () => {
  const { auction } = useAuction();
  return useQuery('sessionsCounter', () => auction.nextSession().then(({ counter }) => counter));
};

export const useMinimumOrder = () => {
  const { auction } = useAuction();
  return useQuery('minimumOrder', () => auction.settings().then(({ orderQuoteVolumeMinimum }) => orderQuoteVolumeMinimum));
};

export const usePrincipalToSubaccount = (p: Principal) => {
  const { auction } = useAuction();
  return useQuery('subaccount_' + p.toText(), async () => auction.principalToSubaccount(p));
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
      return (kind === 'bid' ? auction.queryBids() : auction.queryAsks()).then(([orders, _]) => orders);
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch ${kind}s: ${err}`, { variant: 'error' });
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
      return auction.queryCredits();
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch credits: ${err}`, { variant: 'error' });
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
          queryClient.invalidateQueries(kind === 'bid' ? 'myBids' : 'myAsks');
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
      return auction.queryPriceHistory([], BigInt(limit), BigInt(offset));
    },
    {
      keepPreviousData: true,
      onError: err => {
        enqueueSnackbar(`Failed to fetch price history: ${err}`, { variant: 'error' });
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
