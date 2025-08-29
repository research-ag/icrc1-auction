import { useMemo, useState } from 'react';
import { Box, Button, Table, Typography } from '@mui/joy';
import PageTemplate from '@fe/components/page-template';
import InfoItem from '@fe/components/root/info-item';
import { Principal } from '@dfinity/principal';
import {
  useAuctionQuery,
  useDeleteDarkOrderBook,
  useListDarkOrderBooks,
  useQuoteLedger,
  useTokenInfoMap
} from '@fe/integration';
import DarkOrdersModal from './dark-orders.modal';

type ParsedOrder = { kind: 'ask' | 'bid'; volume: number; price: number };

const DarkOrders = () => {
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editLedger, setEditLedger] = useState<Principal | null>(null);
  const [editOrders, setEditOrders] = useState<ParsedOrder[] | null>(null);

  const openCreate = () => {
    setEditLedger(null);
    setEditOrders(null);
    setIsModalOpen(true);
  };
  const openEdit = (ledger: Principal) => {
    setEditLedger(ledger);
    const found = rows.find(r => r.ledger.toText() === ledger.toText());
    setEditOrders(found ? found.orders : null);
    setIsModalOpen(true);
  };
  const closeModal = () => { setIsModalOpen(false); setEditOrders(null); };

  const { data: auctionQuery } = useAuctionQuery();
  const { data: darkBooks } = useListDarkOrderBooks(auctionQuery);
  const { data: symbols } = useTokenInfoMap();
  const { data: quoteLedger } = useQuoteLedger();
  const { mutate: deleteBook } = useDeleteDarkOrderBook();

  const getInfo = (ledger: Principal): { symbol: string; decimals: number } => {
    const mapItem = (symbols || []).find(([p]) => p.toText() == ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  const getQuoteDecimals = (): number => {
    const mapItem = (symbols || []).find(([p]) => p.toText() === (quoteLedger?.toText() || ''));
    return mapItem ? mapItem[1].decimals : 0;
  };

  const decodeOrders = (enc: [Uint8Array | number[], Uint8Array | number[]], baseDecimals: number, quoteDecimals: number): ParsedOrder[] => {
    try {
      const text = String.fromCharCode(...Object.values(enc[0]));
      if (!text) return [];
      const scaleExp = quoteDecimals - baseDecimals;
      const scaleDiv = Math.pow(10, scaleExp);
      const volDiv = Math.pow(10, baseDecimals);
      return text.split(';').filter(Boolean).map(part => {
        const [k, vStr, pStr] = part.split(':');
        const kind = (k === 'ask' ? 'ask' : 'bid') as 'ask' | 'bid';
        const vInt = Number(vStr);
        const pInt = Number(pStr);
        const volume = isFinite(vInt) ? vInt / volDiv : 0;
        const price = isFinite(pInt) ? pInt / scaleDiv : 0;
        return { kind, volume, price };
      });
    } catch (_) {
      return [];
    }
  };

  const rows = useMemo(() => {
    const qd = getQuoteDecimals();
    return (darkBooks ?? []).map(([ledger, enc]) => {
      const info = getInfo(ledger);
      const orders = decodeOrders(enc, info.decimals, qd);
      return { ledger, symbol: info.symbol, orders };
    });
  }, [darkBooks, symbols, quoteLedger]);

  return (
    <PageTemplate title="Dark Orders" addButtonTitle="Set dark order book" onAddButtonClick={openCreate}>
      <Box sx={{ width: '100%', overflow: 'auto' }}>
        <Table>
          <colgroup>
            <col style={{ width: '150px' }}/>
            <col style={{ width: '150px' }}/>
            <col/>
            <col style={{ width: '160px' }}/>
          </colgroup>
          <thead>
          <tr>
            <th>Token symbol</th>
            <th>Ledger Principal</th>
            <th>Orders</th>
            <th></th>
          </tr>
          </thead>
          <tbody>
          {rows.map(({ ledger, symbol, orders }, i) => (
            <tr key={i}>
              <td><InfoItem content={symbol} withCopy={true}/></td>
              <td><Typography level="body-sm">{ledger.toText()}</Typography></td>
              <td>
                {orders.length === 0 ? (
                  <Typography level="body-sm" color="neutral">No orders</Typography>
                ) : (
                  <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
                    {orders.map((o, idx) => (
                      <Typography key={idx} level="body-sm">
                        {o.kind.toUpperCase()} {o.volume} @ {o.price}
                      </Typography>
                    ))}
                  </Box>
                )}
              </td>
              <td>
                <Box sx={{ display: 'flex', gap: 1 }}>
                  <Button size="sm" onClick={() => openEdit(ledger)}>Edit</Button>
                  <Button size="sm" color="danger" onClick={() => deleteBook(ledger)}>Remove</Button>
                </Box>
              </td>
            </tr>
          ))}
          </tbody>
        </Table>
      </Box>
      <DarkOrdersModal isOpen={isModalOpen} onClose={closeModal} editLedger={editLedger} editOrders={editOrders}/>
    </PageTemplate>
  );
};

export default DarkOrders;
