import { Box, Button, Table } from '@mui/joy';

import { useIsAdmin, useGetAdmins, useRemoveAdmin } from '../../integration';

const OwnersTable = () => {
  const { data: owners } = useGetAdmins();

  const isOwner = useIsAdmin();

  const { mutate: removeOwner } = useRemoveAdmin();

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          {isOwner && <col style={{ width: '100px' }} />}
          <col style={{ width: '460px' }} />
        </colgroup>

        <thead>
          <tr>
            {isOwner && <th></th>}
            <th>Principal</th>
          </tr>
        </thead>
        <tbody>
          {(owners ?? []).map(ownerPrincipal => {
            return (
              <tr key={ownerPrincipal.toText()}>
                {isOwner && (
                  <td>
                    <Button
                      onClick={() => {
                        removeOwner(ownerPrincipal);
                      }}
                      color="danger"
                      size="sm"
                      disabled={owners?.length === 1}>
                      Remove
                    </Button>
                  </td>
                )}
                <td>{ownerPrincipal.toText()}</td>
              </tr>
            );
          })}
        </tbody>
      </Table>
    </Box>
  );
};

export default OwnersTable;
