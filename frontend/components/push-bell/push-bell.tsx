import { useState } from 'react';
import { Box, Button, Chip, Modal, ModalClose, ModalDialog, Typography, IconButton } from '@mui/joy';
import { Notifications } from '@mui/icons-material';
import { SxProps } from '@mui/joy/styles/types';
import { useWebPush } from '@fe/integration/push';
import { useIdentity } from '@fe/integration/identity';

interface PushBellProps {
  sx?: SxProps;
}

const colorByState = (enabled: boolean): 'success' | 'danger' => (enabled ? 'success' : 'danger');

const PushBell = ({ sx }: PushBellProps) => {
  const { status, enable, disable, loading } = useWebPush();
  const [open, setOpen] = useState(false);

  const effectiveEnabled = !!status.effectiveEnabled;

  const { identity } = useIdentity();

  return (
    <>
      <IconButton
        size="sm"
        variant="soft"
        color={colorByState(effectiveEnabled)}
        disabled={identity.getPrincipal().isAnonymous() || !('Notification' in window)}
        onClick={() => setOpen(true)}
        sx={sx}
      >
        <Notifications />
      </IconButton>
      <Modal open={open} onClose={() => setOpen(false)}>
        <ModalDialog sx={{ width: 'calc(100% - 50px)', maxWidth: '520px' }}>
          <ModalClose />
          <Typography level="h4" sx={{ mb: 1 }}>Push notifications</Typography>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
              <Typography level="body-sm">Permission:</Typography>
              <Chip size="sm" color={status.permission === 'granted' ? 'success' : status.permission === 'denied' ? 'danger' : 'neutral'}>
                {status.permission}
              </Chip>
            </Box>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
              <Typography level="body-sm">Browser subscription:</Typography>
              <Chip size="sm" color={status.subscribed ? 'success' : 'neutral'}>
                {status.subscribed ? 'subscribed' : 'not subscribed'}
              </Chip>
            </Box>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
              <Typography level="body-sm">App setting:</Typography>
              <Chip size="sm" color={status.enabledByUserSettings ? 'success' : 'neutral'}>
                {status.enabledByUserSettings ? 'enabled' : 'disabled'}
              </Chip>
            </Box>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
              <Typography level="body-sm">Effective:</Typography>
              <Chip size="sm" color={effectiveEnabled ? 'success' : 'danger'}>
                {effectiveEnabled ? 'enabled' : 'disabled'}
              </Chip>
            </Box>
            {status.lastError && (
              <Typography level="body-sm" color="danger" sx={{ mt: 0.5 }}>
                {status.lastError}
              </Typography>
            )}
            <Box sx={{ display: 'flex', gap: 1, mt: 1 }}>
              <Button size="sm" color="success" loading={loading} onClick={() => enable()}>Enable</Button>
              <Button size="sm" color="neutral" loading={loading} onClick={() => disable()}>Disable</Button>
            </Box>
          </Box>
        </ModalDialog>
      </Modal>
    </>
  );
};

export default PushBell;
