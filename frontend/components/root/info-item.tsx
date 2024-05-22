import { useRef, useState } from 'react';
import { Box, Typography, Tooltip } from '@mui/joy';
import ContentCopyIcon from '@mui/icons-material/ContentCopy';
import RefreshIcon from '@mui/icons-material/Refresh';

interface InfoItemProps {
  label?: string;
  content: string;
  withCopy?: boolean;
  withRefresh?: boolean;
  onRefresh?: () => void;
}

const InfoItem = ({ label, content, withCopy, withRefresh, onRefresh }: InfoItemProps) => {
  const timerID = useRef<NodeJS.Timeout | null>(null);

  const [isCopied, setIsCopied] = useState(false);

  const copyTooltipTitle = isCopied ? '✓ Copied' : 'Copy to clipboard';

  return (
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
      <Typography sx={{ fontWeight: 700 }} level="body-xs">
        {label ? `${label}: ` : ''}
      </Typography>
      <Typography level="body-xs">{content}</Typography>
      {withCopy && (
        <Tooltip title={copyTooltipTitle} disableInteractive>
          <ContentCopyIcon
            sx={{ fontSize: '16px', cursor: 'pointer', marginLeft: 1 }}
            onClick={() => {
              const clipboardItem = new ClipboardItem({
                'text/plain': new Blob([content], { type: 'text/plain' }),
              });

              navigator.clipboard.write([clipboardItem]);

              if (timerID.current) {
                clearTimeout(timerID.current);
              }

              setIsCopied(true);

              timerID.current = setTimeout(() => {
                setIsCopied(false);
              }, 3000);
            }}
          />
        </Tooltip>
      )}
      {withRefresh && (
        <Tooltip title="Refresh" disableInteractive>
          <RefreshIcon sx={{ fontSize: '16px', cursor: 'pointer', marginLeft: 1 }} onClick={onRefresh} />
        </Tooltip>
      )}
    </Box>
  );
};

export default InfoItem;
