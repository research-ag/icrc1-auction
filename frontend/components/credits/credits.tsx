import PageTemplate from '../../components/page-template';

import CreditsTable from './credits-table';
import DepositModal from './deposit-modal';
import { useState } from 'react';
import { useTrustedLedger } from '../../integration';

const Credits = () => {
  const [isDepositModalOpen, setIsDepositModalOpen] = useState(false);
  const openDepositModal = () => setIsDepositModalOpen(true);
  const closeDepositModal = () => setIsDepositModalOpen(false);

  return (
    <PageTemplate title="Credits" addButtonTitle="Deposit" onAddButtonClick={openDepositModal}>
      <CreditsTable />
      <DepositModal isOpen={isDepositModalOpen} onClose={closeDepositModal} />
    </PageTemplate>
  );
};

export default Credits;
