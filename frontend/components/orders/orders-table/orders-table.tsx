import { Box, Button, Table } from '@mui/joy';

import { useCancelOrder, useListOrders, useTokenSymbolsMap } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';

export type OrdersTableProps = { kind: 'ask' | 'bid' };

const OrdersTable = ({ kind }: OrdersTableProps) => {
  const { data: orders } = useListOrders(kind);
  const { mutate: cancelOrder } = useCancelOrder(kind);

  const { data: symbols } = useTokenSymbolsMap();
  const getSymbol = (ledger: Principal): string => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : '-';
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '200px' }} />
          <col style={{ width: '110px' }} />
          <col style={{ width: '110px' }} />
          <col style={{ width: '80px' }} />
        </colgroup>
        <thead>
          <tr>
            <th>Token symbol</th>
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
                  <InfoItem content={getSymbol(order.icrc1Ledger)} withCopy={true} />
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
