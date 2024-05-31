import PageTemplate from '../../components/page-template';

import TransactionsHistoryTable from './transactions-history-table';

const TransactionsHistory = () => {
  return (
    <PageTemplate title="Transactions history">
      <TransactionsHistoryTable />
    </PageTemplate>
  );
};

export default TransactionsHistory;
