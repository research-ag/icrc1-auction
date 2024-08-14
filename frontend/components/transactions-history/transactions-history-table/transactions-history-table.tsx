import { Box, Table } from '@mui/joy';

import { useTokenInfoMap, useTransactionHistory, useQuoteLedger } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';

const TransactionsHistoryTable = () => {
  const { data: data } = useTransactionHistory();

  const { data: quoteLedger } = useQuoteLedger();
  const { data: symbols } = useTokenInfoMap();
  const getInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '160px' }} />
          <col style={{ width: '60px' }} />
          <col style={{ width: '70px' }} />
          <col style={{ width: '160px' }} />
          <col style={{ width: '75px' }} />
          <col style={{ width: '75px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>Timestamp</th>
          <th>Session</th>
          <th>Kind</th>
          <th>Token symbol</th>
          <th>Volume</th>
          <th>Price</th>
        </tr>
        </thead>
        <tbody>
        {(data ?? []).map(([ts, sessionNumber, kind, ledger, volume, price]) => {
          return (
            <tr key={String(ts)}>
              <td>{String(new Date(Number(ts) / 1_000_000))}</td>
              <td>{String(sessionNumber)}</td>
              <td>{'ask' in kind ? 'Ask' : 'Bid'}</td>
              <td>
                <InfoItem content={getInfo(ledger).symbol} withCopy={true} />
              </td>
              <td>{displayWithDecimals(volume, getInfo(ledger).decimals)}</td>
              <td>{displayWithDecimals(price, getInfo(quoteLedger!).decimals - getInfo(ledger).decimals, 6)}</td>
            </tr>
          );
        })}
        </tbody>
      </Table>
    </Box>
  );
};

export default TransactionsHistoryTable;
