import { Box, Table } from '@mui/joy';

import { useAuctionQuery, useDepositHistory, useTokenInfoMap } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals, subaccountToText } from '@fe/utils';

const DepositHistoryTable = () => {
  const { data: auctionQuery } = useAuctionQuery();
  const { data: data } = useDepositHistory(auctionQuery);

  const { data: symbols } = useTokenInfoMap();
  const getInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  const getDestinationLabel = (kind: any) => {
    if ('deposit' in kind || !kind['withdrawal']?.length) {
      return '-';
    }
    if ('btcDirect' in kind['withdrawal'][0]) {
      return 'BTC address: ' + kind['withdrawal'][0]['btcDirect'];
    } else if ('cyclesDirect' in kind['withdrawal'][0]) {
      return 'Canister: ' + kind['withdrawal'][0]['cyclesDirect'].toText();
    } else if ('icrc1Address' in kind['withdrawal'][0]) {
      let p = kind['withdrawal'][0]['icrc1Address'][0];
      let subaccount = kind['withdrawal'][0]['icrc1Address'][1];
      if (subaccount?.length) {
        subaccount[0] = Array.from(Object.values(subaccount[0]));
      }
      return 'ICRC1 account: ' + p.toText() + ', ' + subaccountToText(subaccount);
    }
    return '-';
  };

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '190px' }} />
          <col style={{ width: '90px' }} />
          <col style={{ width: '80px' }} />
          <col style={{ width: '200px' }} />
        </colgroup>
        <thead>
          <tr>
            <th>Timestamp</th>
            <th>Token symbol</th>
            <th>Volume</th>
            <th>Destination</th>
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
                <td>
                  {getDestinationLabel(kind)}
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
