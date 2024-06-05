import { Box, Tab, TabList, Tabs } from '@mui/joy';

import Orders from '../orders';
import ConnectButton from '../../components/connect-button';
import ThemeButton from '../../components/theme-button';
import { useIdentity } from '@fe/integration/identity';

import InfoItem from './info-item';
import { useIsAdmin, useSessionsCounter, useTrustedLedger } from '@fe/integration';
import { useState } from 'react';
import Credits from '../credits';
import TransactionsHistory from '@fe/components/transactions-history';
import Assets from '../assets';
import Owners from '../owners';
import { canisterId } from '@declarations/icrc1_auction';
import PriceHistory from '@fe/components/price-history';
import RunAuctionButton from '@fe/components/run-auction-button';

const Root = () => {
    const {identity} = useIdentity();

    const [tabValue, setTabValue] = useState(0);

    const userPrincipal = identity.getPrincipal().toText();

  const isAdmin = useIsAdmin();

    return (
        <Box
            sx={{
                width: '100%',
                maxWidth: '1200px',
                p: 4,
                mx: 'auto',
            }}>
            <Tabs
                sx={{backgroundColor: 'transparent'}}
                value={tabValue}
                onChange={(_, value) => setTabValue(value as number)}>
                <Box sx={{display: 'flex', justifyContent: 'flex-end'}}>
                    <Box
                        sx={{
                            display: 'flex',
                            flexDirection: 'column',
                            alignItems: 'flex-end',
                            gap: 0.5,
                            marginBottom: 1,
                        }}>
                      {isAdmin && (<RunAuctionButton></RunAuctionButton>)}
                        <InfoItem label="Sessions counter" content={String(useSessionsCounter().data)}/>
                        <InfoItem label="Your principal" content={userPrincipal} withCopy/>
                        <InfoItem label="Trusted ledger" content={useTrustedLedger().data?.toText() || ""} withCopy/>
                        <InfoItem label="Auction principal" content={canisterId} withCopy/>
                    </Box>
                </Box>
                <Box
                    sx={{
                        display: 'flex',
                        alignItems: 'center',
                        marginBottom: 2,
                    }}>
                    <TabList sx={{marginRight: 1, flexGrow: 1}} variant="plain">
                        <Tab color="neutral">Assets</Tab>
                        <Tab color="neutral">My credits</Tab>
                        <Tab color="neutral">Active Bids</Tab>
                        <Tab color="neutral">Active Asks</Tab>
                        <Tab color="neutral">Transaction history</Tab>
                        <Tab color="neutral">Price history</Tab>
                        <Tab color="neutral">Admins</Tab>
                    </TabList>
                    <ConnectButton/>
                    <ThemeButton sx={{marginLeft: 1}}/>
                </Box>
                {tabValue === 0 && <Assets/>}
                {tabValue === 1 && <Credits/>}
                {tabValue === 2 && <Orders kind="bid"/>}
                {tabValue === 3 && <Orders kind="ask"/>}
                {tabValue === 4 && <TransactionsHistory />}
                {tabValue === 5 && <PriceHistory />}
                {tabValue === 6 && <Owners />}
            </Tabs>
        </Box>
    );
};

export default Root;
