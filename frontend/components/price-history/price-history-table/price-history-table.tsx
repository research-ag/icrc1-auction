import { Box, Table } from '@mui/joy';

import { usePriceHistory } from '@fe/integration';
import InfoItem from '../../root/info-item';

const PriceHistoryTable = () => {
  const { data: data } = usePriceHistory();

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '160px' }} />
          <col style={{ width: '70px' }} />
          <col style={{ width: '180px' }} />
          <col style={{ width: '95px' }} />
          <col style={{ width: '95px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>Timestamp</th>
          <th>Session</th>
          <th>Ledger</th>
          <th>Volume</th>
          <th>Price</th>
        </tr>
        </thead>
        <tbody>
        {(data ?? []).map(([ts, sessionNumber, ledger, volume, price]) => {
          return (
            <tr key={String(ts)}>
              <td>{String(new Date(Number(ts) / 1_000_000))}</td>
              <td>{String(sessionNumber)}</td>
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

export default PriceHistoryTable;
