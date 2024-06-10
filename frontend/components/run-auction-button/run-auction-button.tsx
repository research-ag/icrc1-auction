import { Button } from '@mui/joy';
import { useExecuteAuction } from '@fe/integration';


const RunAuctionButton = () => {

  const { mutate: executeAuction, error, isLoading } = useExecuteAuction();

  const handleExecute = () => {
    executeAuction();
  };

  return (
    <Button onClick={handleExecute} color="neutral" disabled={isLoading}>
      Execute auction
    </Button>
  );
};

export default RunAuctionButton;
