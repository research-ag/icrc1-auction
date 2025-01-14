import { Box, Button, Table } from '@mui/joy';

import { useAuctionQuery, useListCredits, useTokenInfoMap } from '@fe/integration';
import WithdrawCreditModal from '../withdraw-credit-modal';
import { useState } from 'react';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';

const CreditsTable = () => {
  const { data: auctionQuery } = useAuctionQuery();
  const { data: credits } = useListCredits(auctionQuery);

  const [withdrawLedger, setWithdrawLedger] = useState('');
  const [isWithdrawModalOpen, setIsWithdrawModalOpen] = useState(false);
  const openWithdrawModal = (ledger: Principal) => {
    setWithdrawLedger(ledger.toText());
    setIsWithdrawModalOpen(true);
  };
  const closeWithdrawModal = () => setIsWithdrawModalOpen(false);

  const { data: symbols } = useTokenInfoMap();
  const getTokenInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '200px' }}/>
          <col style={{ width: '120px' }}/>
          <col style={{ width: '120px' }}/>
          <col style={{ width: '60px' }}/>
        </colgroup>
        <thead>
        <tr>
          <th>Token symbol</th>
          <th>Credit</th>
          <th>Total credit</th>
          <th></th>
        </tr>
        </thead>
        <tbody>
        {(credits ?? []).map(([ledger, credit], i) => {
          return (
            <tr key={i}>
              <td>
                {symbols && <InfoItem content={getTokenInfo(ledger).symbol} withCopy={true}/>}
              </td>
              <td>{displayWithDecimals(credit.available, getTokenInfo(ledger).decimals, 6)}</td>
              <td>{displayWithDecimals(credit.total, getTokenInfo(ledger).decimals, 6)}</td>
              <td>
                <Button onClick={() => openWithdrawModal(ledger)} color="danger" size="sm">
                  Withdraw
                </Button>
              </td>
            </tr>
          );
        })}
        </tbody>
      </Table>
      <WithdrawCreditModal isOpen={isWithdrawModalOpen} onClose={closeWithdrawModal} ledger={withdrawLedger}/>
    </Box>
  );
};

export default CreditsTable;
