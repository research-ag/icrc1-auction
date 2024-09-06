import { Box, Table } from '@mui/joy';

import { usePriceHistory, useTokenInfoMap, useQuoteLedger } from '@fe/integration';
import InfoItem from '../../root/info-item';
import { Principal } from '@dfinity/principal';
import { displayWithDecimals } from '@fe/utils';
import { useEffect, useRef, useState } from 'react';

const PriceHistoryTable = () => {
  const LIMIT = 500;
  const [offset, setOffset] = useState(0);
  const [items, setItems] = useState([] as any[]);
  const { data, isFetching, isError } = usePriceHistory(LIMIT, offset);

  const { data: quoteLedger } = useQuoteLedger();
  const { data: symbols } = useTokenInfoMap();

  const observerRef = useRef(null);

  const getInfo = (ledger: Principal): { symbol: string, decimals: number } => {
    const mapItem = (symbols || []).find(([p, s]) => p.toText() === ledger.toText());
    return mapItem ? mapItem[1] : { symbol: '-', decimals: 0 };
  };

  useEffect(() => {
    if (data) {
      setItems((prevItems) => [...prevItems, ...data]);
    }
  }, [data]);

  // Intersection Observer to detect when we reach the bottom
  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting && !isFetching && !isError) {
          // Load next page when scrolled to bottom
          setOffset((prevOffset) => prevOffset + LIMIT);
        }
      },
      { threshold: 1 }
    );

    if (observerRef.current) {
      observer.observe(observerRef.current);
    }

    return () => {
      if (observerRef.current) {
        observer.unobserve(observerRef.current);
      }
    };
  }, [isFetching, isError]);

  return (
    <Box sx={{ width: '100%', overflow: 'auto' }}>
      <Table>
        <colgroup>
          <col style={{ width: '160px' }} />
          <col style={{ width: '70px' }} />
          <col style={{ width: '180px' }} />
          <col style={{ width: '95px' }} />
          <col style={{ width: '95px' }} />
        </colgroup>
        <thead>
        <tr>
          <th>Timestamp</th>
          <th>Session</th>
          <th>Token symbol</th>
          <th>Volume</th>
          <th>Price</th>
        </tr>
        </thead>
        <tbody>
        {(items ?? []).map(([ts, sessionNumber, ledger, volume, price]) => (
          <tr key={String(ts)}>
            <td>{String(new Date(Number(ts) / 1_000_000))}</td>
            <td>{String(sessionNumber)}</td>
            <td>
              <InfoItem content={getInfo(ledger).symbol} withCopy={true} />
            </td>
            <td>{displayWithDecimals(volume, getInfo(ledger).decimals)}</td>
            <td>{displayWithDecimals(price, getInfo(quoteLedger!).decimals - getInfo(ledger).decimals, 6)}</td>
          </tr>
        ))}
        </tbody>
      </Table>
      <div ref={observerRef} style={{ height: '20px' }} />
      {isFetching && <div>Loading...</div>}
    </Box>
  );
};

export default PriceHistoryTable;
