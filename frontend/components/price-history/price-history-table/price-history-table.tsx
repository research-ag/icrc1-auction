import { Box, Table } from '@mui/joy';

import { usePriceHistory, useTokenInfoMap, useTrustedLedger } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';

const PriceHistoryTable = () => {
  const { data: data } = usePriceHistory();

  const { data: trustedLedger } = useTrustedLedger();
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
          <col style={{ width: '70px' }} />
          <col style={{ width: '180px' }} />
          <col style={{ width: '95px' }} />
          <col style={{ width: '95px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>Timestamp</th>
          <th>Session</th>
          <th>Token symbol</th>
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
                <InfoItem content={getInfo(ledger).symbol} withCopy={true} />
              </td>
              <td>{displayWithDecimals(volume, getInfo(ledger).decimals)}</td>
              <td>{displayWithDecimals(price, getInfo(trustedLedger!).decimals - getInfo(ledger).decimals)}</td>
            </tr>
          );
        })}
        </tbody>
      </Table>
    </Box>
  );
};

export default PriceHistoryTable;
