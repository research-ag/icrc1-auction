import { useState } from 'react';

import PageTemplate from '../../components/page-template';

import OwnersTable from './owners-table';
import AddOwnerModal from './add-owner-modal';
import { useIsAdmin } from '../../integration';

const Owners = () => {
  const [isAddModalOpen, setIsAddModalOpen] = useState(false);
  const openAddModal = () => setIsAddModalOpen(true);
  const closeAddModal = () => setIsAddModalOpen(false);

  const isOwner = useIsAdmin();

  return (
    <PageTemplate title="Admins" addButtonTitle={isOwner ? 'Add new admin' : undefined} onAddButtonClick={openAddModal}>
      <OwnersTable />
      <AddOwnerModal isOpen={isAddModalOpen} onClose={closeAddModal} />
    </PageTemplate>
  );
};

export default Owners;
