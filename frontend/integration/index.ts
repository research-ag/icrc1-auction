import { useMutation, useQuery, useQueryClient } from 'react-query';
import { useSnackbar } from 'notistack';

import { useIdentity } from './identity';
import { Principal } from '@dfinity/principal';
import { useMemo } from 'react';
import { canisterId, createActor } from '@declarations/icrc1_auction';

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

export const useTrustedLedger = () => {
  const { auction } = useAuction();
  return useQuery('trustedLedger', () => auction.getTrustedLedger());
};

export const useSessionsCounter = () => {
  const { auction } = useAuction();
  return useQuery('sessionsCounter', () => auction.sessionsCounter());
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
          enqueueSnackbar(`Failed to add ledger: ${JSON.stringify(res.Err)}`, { variant: 'error' });
        } else {
          queryClient.invalidateQueries('assets');
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
  return useQuery(
    'assets',
    async () => {
      return auction.icrcX_supported_tokens();
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch credits: ${err}`, { variant: 'error' });
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
      return kind === 'bid' ? auction.queryBids() : auction.queryAsks();
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
      return auction.icrcX_all_credits();
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
  return useMutation((icrc1Ledger: Principal) => auction.icrcX_notify({ token: icrc1Ledger }), {
    onSuccess: res => {
      if ('Err' in res) {
        enqueueSnackbar(`Failed to deposit: ${JSON.stringify(res.Err)}`, { variant: 'error' });
      } else {
        queryClient.invalidateQueries('myCredits');
        enqueueSnackbar(`Deposited ${Number(res.Ok)} tokens successfully`, { variant: 'success' });
      }
    },
    onError: err => {
      enqueueSnackbar(`Failed to deposit: ${err}`, { variant: 'error' });
    },
  });
};

export const usePlaceOrder = (kind: 'ask' | 'bid') => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(
    (formObj: { ledger: string; volume: number; price: number }) =>
        (kind === 'bid' ? auction.placeBids : auction.placeAsks).bind(auction)(
            [[
              Principal.fromText(formObj.ledger),
              BigInt(formObj.volume),
              Number(formObj.price),
            ]]
      ),
    {
      onSuccess: ([res]) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to place a ${kind}: ${JSON.stringify(res.Err)}`, { variant: 'error' });
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
      (orderId: bigint) => (kind === 'bid' ? auction.cancelBids([orderId]) : auction.cancelAsks([orderId])),
    {
      onSuccess: ([res]) => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to cancel the ${kind}: ${JSON.stringify(res.Err)}`, { variant: 'error' });
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

export const useHistory = () => {
  const { auction } = useAuction();
  const { enqueueSnackbar } = useSnackbar();
  return useQuery(
    'history',
    async () => {
      return auction.queryTransactionHistory(BigInt(10000), BigInt(0));
    },
    {
      onError: err => {
        enqueueSnackbar(`Failed to fetch history: ${err}`, { variant: 'error' });
      },
    },
  );
};

export const useWithdrawCredit = () => {
  const { auction } = useAuction();
  const queryClient = useQueryClient();
  const { enqueueSnackbar } = useSnackbar();
  return useMutation(
    (formObj: { ledger: string; amount: number; subaccount: Uint8Array | null }) =>
      auction.icrcX_withdraw({
        token: Principal.fromText(formObj.ledger),
        to_subaccount: formObj.subaccount ? [formObj.subaccount] : [],
        amount: BigInt(formObj.amount),
      }),
    {
      onSuccess: res => {
        if ('Err' in res) {
          enqueueSnackbar(`Failed to withdraw credit: ${JSON.stringify(res.Err)}`, { variant: 'error' });
        } else {
          queryClient.invalidateQueries('myCredits');
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
