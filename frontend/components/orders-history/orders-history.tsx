import PageTemplate from '../../components/page-template';

import OrdersHistoryTable from './orders-history-table';

const OrdersHistory = () => {
  return (
    <PageTemplate title="Orders history">
      <OrdersHistoryTable />
    </PageTemplate>
  );
};

export default OrdersHistory;
