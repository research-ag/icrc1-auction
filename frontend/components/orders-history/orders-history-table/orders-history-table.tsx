import { Box, Table } from '@mui/joy';

import { useHistory } from '../../../integration';
import InfoItem from '../../root/info-item';

const OrdersHistoryTable = () => {
  const { data: data } = useHistory();

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '180px' }} />
          <col style={{ width: '80px' }} />
          <col style={{ width: '180px' }} />
          <col style={{ width: '80px' }} />
          <col style={{ width: '80px' }} />
        </colgroup>
        <thead>
          <tr>
            <th>Timestamp</th>
            <th>Kind</th>
            <th>Ledger</th>
            <th>Volume</th>
            <th>Price</th>
          </tr>
        </thead>
        <tbody>
          {(data ?? []).map(([ts, kind, ledger, volume, price]) => {
            return (
              <tr key={String(ts)}>
                <td>{String(new Date(Number(ts) / 1_000_000))}</td>
                <td>{'ask' in kind ? 'Ask' : 'Bid'}</td>
                <td>
                  <InfoItem content={ledger.toText()} withCopy={true} />
                </td>
                <td>{String(volume)}</td>
                <td>{String(price)}</td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </Box>
  );
};

export default OrdersHistoryTable;
