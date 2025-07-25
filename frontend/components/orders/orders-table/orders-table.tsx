import { Box, Button, Table } from '@mui/joy';

import { useAuctionQuery, useCancelOrder, useListOrders, useQuoteLedger, useTokenInfoMap } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';

export type OrdersTableProps = { kind: 'ask' | 'bid' };

const OrdersTable = ({ kind }: OrdersTableProps) => {
  const { data: auctionQuery } = useAuctionQuery();
  const { data: orders } = useListOrders(auctionQuery, kind);
  const { mutate: cancelOrder } = useCancelOrder(kind);

  const { data: symbols } = useTokenInfoMap();
  const { data: quoteLedger } = useQuoteLedger();
  const getInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    const mapItem = (symbols || []).find(([p, _]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '150px' }}/>
          <col style={{ width: '80px' }}/>
          <col style={{ width: '95px' }}/>
          <col style={{ width: '95px' }}/>
          <col style={{ width: '80px' }}/>
        </colgroup>
        <thead>
        <tr>
          <th>Token symbol</th>
          <th>Type</th>
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
                <InfoItem content={getInfo(order.icrc1Ledger).symbol} withCopy={true}/>
              </td>
              <td>{Object.keys(order.orderBookType)[0]}</td>
              <td>{displayWithDecimals(order.price, getInfo(quoteLedger!).decimals - getInfo(order.icrc1Ledger).decimals, 6)}</td>
              <td>{displayWithDecimals(order.volume, getInfo(order.icrc1Ledger).decimals)}</td>
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
