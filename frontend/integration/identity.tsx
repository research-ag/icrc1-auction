import { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { AnonymousIdentity, Identity } from '@icp-sdk/core/agent';
import { useQueryClient } from 'react-query';

interface IIdentityContext {
  identity: Identity;
  setIdentity: (value: Identity) => void;
}

const IdentityContext = createContext<IIdentityContext>({
  identity: new AnonymousIdentity(),
  setIdentity: () => null,
});

interface IdentityProviderProps {
  children: React.ReactNode;
}

export const IdentityProvider = ({ children }: IdentityProviderProps) => {
  const [identity, setIdentity] = useState<Identity>(new AnonymousIdentity());
  const queryClient = useQueryClient();
  const principalText = useMemo(() => identity?.getPrincipal?.().toText?.() ?? '2vxsx-fae', [identity]);

  // Centralized cache invalidation on identity change (exclude price-history)
  useEffect(() => {
    if (!principalText) return;
    // Invalidate identity-scoped queries so the active tab refreshes immediately
    try {
      queryClient.invalidateQueries('auctionQuery');
      queryClient.invalidateQueries('myCredits');
      queryClient.invalidateQueries('myBids');
      queryClient.invalidateQueries('myAsks');
      queryClient.invalidateQueries('dark-order-books');
      queryClient.invalidateQueries('deposit-history');
      queryClient.invalidateQueries('transaction-history');
      queryClient.invalidateQueries('myPoints');
      queryClient.invalidateQueries(['userSettings']);
    } catch (_e) {
      // no-op
    }
  }, [principalText, queryClient]);

  return <IdentityContext.Provider value={{ identity, setIdentity }}>{children}</IdentityContext.Provider>;
};

export const useIdentity = () => useContext(IdentityContext);
