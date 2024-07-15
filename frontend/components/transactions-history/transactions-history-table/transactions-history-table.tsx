import { Box, Table } from '@mui/joy';

import { useTokenSymbolsMap, useTransactionHistory } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';

const TransactionsHistoryTable = () => {
  const { data: data } = useTransactionHistory();

  const { data: symbols } = useTokenSymbolsMap();
  const getSymbol = (ledger: Principal): string => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : '-';
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
                  <InfoItem content={getSymbol(ledger)} withCopy={true} />
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

export default TransactionsHistoryTable;
