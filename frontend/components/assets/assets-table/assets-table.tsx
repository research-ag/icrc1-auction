import { Box, Table } from '@mui/joy';

import { useTokenSymbolsMap } from '@fe/integration';
import InfoItem from '../../root/info-item';

const AssetsTable = () => {
  const { data: symbols } = useTokenSymbolsMap();
  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '30px' }} />
          <col style={{ width: '70px' }} />
          <col style={{ width: '460px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>#</th>
          <th>Symbol</th>
          <th>Ledger principal</th>
        </tr>
        </thead>
        <tbody>
        {(symbols ?? []).map(([p, s], i) => {
            return (
              <tr key={i}>
                <td>{String(i)}</td>
                <td>
                  <InfoItem content={s} withCopy={true} />
                </td>
                <td>
                  <InfoItem content={p.toText()} withCopy={true} />
                </td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </Box>
  );
};

export default AssetsTable;
