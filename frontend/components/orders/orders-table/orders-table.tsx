import { Box, Button, Table } from '@mui/joy';

import { useCancelOrder, useListOrders } from '../../../integration';
import InfoItem from '../../root/info-item';

export type OrdersTableProps = { kind: 'ask' | 'bid' };

const OrdersTable = ({ kind }: OrdersTableProps) => {
  const { data: orders } = useListOrders(kind);
  const { mutate: cancelOrder } = useCancelOrder(kind);

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
            <th>Ledger principal</th>
            <th>Price</th>
            <th>Volume</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(orders ?? []).map(([orderId, order], i) => {
            return (
              <tr key={i}>
                <td>
                  <InfoItem content={order.icrc1Ledger.toText()} withCopy={true} />
                </td>
                <td>{String(order.price)}</td>
                <td>{String(order.volume)}</td>
                <td>
                  <Button onClick={() => cancelOrder(orderId)} color="danger" size="sm">
                    Cancel {kind}
                  </Button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </Box>
  );
};

export default OrdersTable;
