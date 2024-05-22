import { Box, Button, Table } from '@mui/joy';

import { useListCredits } from '../../../integration';
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

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '200px' }} />
          <col style={{ width: '240px' }} />
          <col style={{ width: '60px' }} />
        </colgroup>
        <thead>
          <tr>
            <th>Ledger principal</th>
            <th>Credit</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(credits ?? []).map(([ledger, credit], i) => {
            return (
              <tr key={i}>
                <td>
                  <InfoItem content={ledger.toText()} withCopy={true} />
                </td>
                <td>{String(credit)}</td>
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
