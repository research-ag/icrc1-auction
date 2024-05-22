import PageTemplate from '../../components/page-template';
import AssetsTable from './assets-table';
import { useIsAdmin } from '../../integration';
import AddAssetModal from './add-asset-modal';
import { useState } from 'react';

const Assets = () => {
  const isAdmin = useIsAdmin();
  const [isAddModalOpen, setIsAddModalOpen] = useState(false);
  const openAddModal = () => setIsAddModalOpen(true);
  const closeAddModal = () => setIsAddModalOpen(false);

  return (
    <PageTemplate title="Assets" addButtonTitle={isAdmin ? 'Register new' : ''} onAddButtonClick={openAddModal}>
      <AssetsTable />
      <AddAssetModal isOpen={isAddModalOpen} onClose={closeAddModal} />
    </PageTemplate>
  );
};

export default Assets;
