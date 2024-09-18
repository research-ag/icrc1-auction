import PageTemplate from '../../components/page-template';

import DepositHistoryTable from './deposit-history-table';
import { useState } from 'react';
import DepositModal from '@fe/components/credits/deposit-modal';

const DepositHistory = () => {
  const [isDepositModalOpen, setIsDepositModalOpen] = useState(false);
  const openDepositModal = () => setIsDepositModalOpen(true);
  const closeDepositModal = () => setIsDepositModalOpen(false);

  return (
    <PageTemplate title="Deposit history" addButtonTitle="Deposit" onAddButtonClick={openDepositModal}>
      <DepositHistoryTable />
      <DepositModal isOpen={isDepositModalOpen} onClose={closeDepositModal} />
    </PageTemplate>
  );
};

export default DepositHistory;
