import { Box, Table } from '@mui/joy';

import {useAuctionQuery, useDepositHistory, useQuoteLedger, useTokenInfoMap} from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';

const DepositHistoryTable = () => {
  const { data: auctionQuery } = useAuctionQuery();
  const { data: data } = useDepositHistory(auctionQuery);

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
          <col style={{ width: '290px' }} />
          <col style={{ width: '160px' }} />
          <col style={{ width: '150px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>Timestamp</th>
          <th>Token symbol</th>
          <th>Volume</th>
        </tr>
        </thead>
        <tbody>
        {(data ?? []).map(([ts, kind, ledger, volume]) => {
          return (
            <tr key={String(ts)}>
              <td>{String(new Date(Number(ts) / 1_000_000))}</td>
              <td>
                <InfoItem content={getInfo(ledger).symbol} withCopy={true} />
              </td>
              <td style={{ color: 'withdrawal' in kind ? 'red' : 'green' }}>
                {('withdrawal' in kind ? '-' : '+') + displayWithDecimals(volume, getInfo(ledger).decimals)}
              </td>
            </tr>
          );
        })}
        </tbody>
      </Table>
    </Box>
  );
};

export default DepositHistoryTable;
