import { Box, Table } from '@mui/joy';

import { useTokenInfoMap } from '@fe/integration';
import InfoItem from '../../root/info-item';

const AssetsTable = () => {
  const { data: symbols } = useTokenInfoMap();
  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '30px' }} />
          <col style={{ width: '70px' }} />
          <col style={{ width: '380px' }} />
          <col style={{ width: '80px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>#</th>
          <th>Symbol</th>
          <th>Ledger principal</th>
          <th>Decimals</th>
        </tr>
        </thead>
        <tbody>
        {(symbols ?? []).map(([p, { symbol, decimals }], i) => {
            return (
              <tr key={i}>
                <td>{String(i)}</td>
                <td>
                  <InfoItem content={symbol} withCopy={true} />
                </td>
                <td>
                  <InfoItem content={p.toText()} withCopy={true} />
                </td>
                <td>{String(decimals)}</td>
              </tr>
            );
        })}
        </tbody>
      </Table>
    </Box>
  );
};

export default AssetsTable;
