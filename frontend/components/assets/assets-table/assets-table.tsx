import { Box, Table } from '@mui/joy';

import { useListAssets } from '../../../integration';
import InfoItem from '../../root/info-item';

const AssetsTable = () => {
  const { data: assets } = useListAssets();
  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '100px' }} />
          <col style={{ width: '460px' }} />
        </colgroup>
        <thead>
          <tr>
            <th>#</th>
            <th>Ledger principal</th>
          </tr>
        </thead>
        <tbody>
          {(assets ?? []).map((p, i) => {
            return (
              <tr key={i}>
                <td>{String(i)}</td>
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
