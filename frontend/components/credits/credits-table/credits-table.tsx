import { Box, Button, Table } from '@mui/joy';

import { useListCredits, useTokenSymbolsMap } from '@fe/integration';
import WithdrawCreditModal from '../withdraw-credit-modal';
import { useState } from 'react';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';

const CreditsTable = () => {
  const { data: credits } = useListCredits();

  const [withdrawLedger, setWithdrawLedger] = useState('');
  const [isWithdrawModalOpen, setIsWithdrawModalOpen] = useState(false);
  const openWithdrawModal = (ledger: Principal) => {
    setWithdrawLedger(ledger.toText());
    setIsWithdrawModalOpen(true);
  };
  const closeWithdrawModal = () => setIsWithdrawModalOpen(false);

  const { data: symbols } = useTokenSymbolsMap();
  const getSymbol = (ledger: Principal): string => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : '-';
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '200px' }} />
          <col style={{ width: '120px' }} />
          <col style={{ width: '120px' }} />
          <col style={{ width: '60px' }} />
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
                  {symbols && <InfoItem content={getSymbol(ledger)} withCopy={true} />}
                </td>
                <td>{String(credit.available)}</td>
                <td>{String(credit.total)}</td>
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
      <WithdrawCreditModal isOpen={isWithdrawModalOpen} onClose={closeWithdrawModal} ledger={withdrawLedger} />
    </Box>
  );
};

export default CreditsTable;
