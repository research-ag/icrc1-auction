import { createContext, useContext, useState } from 'react';
import { AnonymousIdentity, Identity } from '@dfinity/agent';

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

  return <IdentityContext.Provider value={{ identity, setIdentity }}>{children}</IdentityContext.Provider>;
};

export const useIdentity = () => useContext(IdentityContext);
