import { Box, Tab, TabList, Tabs, Typography } from '@mui/joy';

import Orders from '../orders';
import ConnectButton from '../../components/connect-button';
import ThemeButton from '../../components/theme-button';
import { useIdentity } from '@fe/integration/identity';

import InfoItem from './info-item';
import {
  defaultAuctionCanisterId,
  updateAuctionCanisterId,
  useAuctionCanisterId,
  useIsAdmin,
  usePoints,
  useMinimumOrder,
  useQuoteLedger,
  useSessionsCounter,
  useTokenInfoMap,
  useAuctionQuery,
} from '@fe/integration';
import { useEffect, useState } from 'react';
import Credits from '../credits';
import TransactionsHistory from '@fe/components/transactions-history';
import Assets from '../assets';
import Owners from '../owners';
import PriceHistory from '@fe/components/price-history';
import { Ed25519KeyIdentity } from '@dfinity/identity';
import { AnonymousIdentity, Identity } from '@dfinity/agent';
import { useQueryClient } from 'react-query';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';
import DepositHistory from '@fe/components/deposit-history';

const Root = () => {
  const { identity, setIdentity } = useIdentity();

  const [tabValue, setTabValue] = useState(0);

  const userPrincipal = identity.getPrincipal().toText();

  const isAdmin = useIsAdmin();

  const { data: quoteLedger } = useQuoteLedger();
  const { data: symbols } = useTokenInfoMap();
  const { data: minimumOrder } = useMinimumOrder();
  const { data: auctionQuery } = useAuctionQuery();
  const { data: points } = usePoints(auctionQuery);
  const getInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    try {
      const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
      return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
    } catch (err) {
      return { symbol: '-', decimals: 0 };
    }
  };

  const [auctionIdInput, setAuctionIdInput] = useState<string>(useAuctionCanisterId());
  const [auctionId, setAuctionId] = useState<string>(useAuctionCanisterId());

  useEffect(() => {
    try {
      Principal.fromText(auctionIdInput);
      updateAuctionCanisterId(auctionIdInput);
    } catch (err) {
    }
  }, [auctionIdInput]);

  useEffect(() => {
    // refresh UI
    let id = useAuctionCanisterId();
    setAuctionIdInput(id);
    setAuctionId(id);
  }, [useAuctionCanisterId()]);

  const onSeedInput = async (seed: string) => {
    const seedToIdentity: (seed: string) => Identity | null = seed => {
      const seedBuf = new Uint8Array(new ArrayBuffer(32));
      if (seed.length && seed.length > 0 && seed.length <= 32) {
        seedBuf.set(new TextEncoder().encode(seed));
        return Ed25519KeyIdentity.generate(seedBuf);
      }
      return null;
    };
    let newIdentity = seedToIdentity(seed) || new AnonymousIdentity();
    if (identity.getPrincipal().toText() !== newIdentity.getPrincipal().toText()) {
      setIdentity(newIdentity);
      const queryClient = useQueryClient();
      await Promise.all([
        queryClient.invalidateQueries('auctionQuery'),
        queryClient.invalidateQueries('transaction-history'),
        queryClient.invalidateQueries('deposit-history'),
      ]);
    }
  };

  return (
    <Box
      sx={{
        width: '100%',
        maxWidth: '1200px',
        p: 4,
        mx: 'auto',
      }}>
      <Tabs
        sx={{ backgroundColor: 'transparent' }}
        value={tabValue}
        onChange={(_, value) => setTabValue(value as number)}>
        <Box sx={{ display: 'flex', justifyContent: 'flex-end' }}>
          <Box
            sx={{
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'flex-end',
              gap: 0.5,
              marginBottom: 1,
            }}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
              <Typography sx={{ fontWeight: 700 }} level="body-xs">Auction backend:</Typography>
              <input type="text" value={auctionIdInput}
                     onChange={e => setAuctionIdInput(e.target.value)}></input>
              <button onClick={e => setAuctionIdInput(defaultAuctionCanisterId)}>Reset</button>
            </Box>
            <InfoItem label="Sessions counter" content={String(useSessionsCounter().data)} />
            <InfoItem label="Your principal" content={userPrincipal} withCopy />
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
              <Typography sx={{ fontWeight: 700 }} level="body-xs">Principal seed:</Typography>
              <input type="text" onChange={e => onSeedInput(e.target.value)}></input>
            </Box>
            <InfoItem label="Quote currency ledger" content={quoteLedger?.toText() || ''} withCopy />
            <InfoItem label="Auction principal" content={auctionId} withCopy />
            <InfoItem label="Minimum order size"
                      content={displayWithDecimals(minimumOrder || 0, getInfo(quoteLedger!).decimals, 6)} />
            <InfoItem label="Points"
                      content={'' + Number(points)} />
          </Box>
        </Box>
        <Box
          sx={{
            display: 'flex',
            alignItems: 'center',
            marginBottom: 2,
          }}>
          <TabList sx={{ marginRight: 1, flexGrow: 1 }} variant="plain">
            <Tab color="neutral">Assets</Tab>
            <Tab color="neutral">My credits</Tab>
            <Tab color="neutral">Active Bids</Tab>
            <Tab color="neutral">Active Asks</Tab>
            <Tab color="neutral">Deposit history</Tab>
            <Tab color="neutral">Transaction history</Tab>
            <Tab color="neutral">Price history</Tab>
            <Tab color="neutral">Admins</Tab>
          </TabList>
          <ConnectButton />
          <ThemeButton sx={{ marginLeft: 1 }} />
        </Box>
        {tabValue === 0 && <Assets />}
        {tabValue === 1 && <Credits />}
        {tabValue === 2 && <Orders kind="bid" />}
        {tabValue === 3 && <Orders kind="ask" />}
        {tabValue === 4 && <DepositHistory />}
        {tabValue === 5 && <TransactionsHistory />}
        {tabValue === 6 && <PriceHistory />}
        {tabValue === 7 && <Owners />}
      </Tabs>
    </Box>
  );
};

export default Root;
