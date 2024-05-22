import { useState } from 'react';

import PageTemplate from '../../components/page-template';

import OrdersTable from './orders-table';
import PlaceOrderModal from './place-order-modal';

type OrdersProps = { kind: 'bid' | 'ask' };

const Orders = ({ kind }: OrdersProps) => {
  const [isAddModalOpen, setIsAddModalOpen] = useState(false);
  const openAddModal = () => setIsAddModalOpen(true);
  const closeAddModal = () => setIsAddModalOpen(false);

  return (
    <PageTemplate
      title={kind === 'bid' ? 'Bids' : 'Asks'}
      addButtonTitle={'Place new ' + kind}
      onAddButtonClick={openAddModal}>
      <OrdersTable kind={kind} />
      <PlaceOrderModal kind={kind} isOpen={isAddModalOpen} onClose={closeAddModal} />
    </PageTemplate>
  );
};

export default Orders;
