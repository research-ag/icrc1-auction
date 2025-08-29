import { useEffect, useMemo, useState } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { z as zod } from 'zod';
import { zodResolver } from '@hookform/resolvers/zod';
import {
  Box,
  Button,
  FormControl,
  FormLabel,
  Input,
  Modal,
  ModalClose,
  ModalDialog,
  Radio,
  RadioGroup,
  Typography,
  Select,
  Option,
} from '@mui/joy';
import { Principal } from '@dfinity/principal';
import { useManageDarkOrderBook, useQuoteLedger, useTokenInfoMap } from '@fe/integration';
import ErrorAlert from '@fe/components/error-alert';

export type DarkOrdersModalProps = {
  isOpen: boolean;
  onClose: () => void;
  editLedger: Principal | null;
  editOrders?: { kind: 'ask' | 'bid'; volume: number; price: number }[] | null;
};

type OrderRow = { kind: 'ask' | 'bid'; volume: string; price: string };

type FormValues = {
  symbol: string;
  rows: OrderRow[];
};

const schema = zod.object({
  symbol: zod.string().min(1),
  rows: zod
    .array(
      zod.object({
        kind: zod.enum(['ask', 'bid']),
        volume: zod.string().refine(v => !isNaN(Number(v)) && Number(v) > 0, 'Volume must be a number > 0'),
        price: zod.string().refine(v => !isNaN(Number(v)) && Number(v) > 0, 'Price must be a number > 0'),
      }),
    )
    .min(1, 'Add at least one order'),
});

const DarkOrdersModal = ({ isOpen, onClose, editLedger, editOrders }: DarkOrdersModalProps) => {
  const defaultValues: FormValues = useMemo(
    () => ({ symbol: '', rows: [{ kind: 'bid', volume: '', price: '' }] }),
    [],
  );

  const { control, handleSubmit, reset, watch } = useForm<FormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const rows = watch('rows');

  const { data: symbols } = useTokenInfoMap();
  const { data: quoteLedger } = useQuoteLedger();
  const { mutate: manage, error, isLoading, reset: resetApi } = useManageDarkOrderBook();

  const getLedgerPrincipal = (symbol: string): Principal | null => {
    const mapItem = (symbols || []).find(([p, s]) => s.symbol === symbol);
    return mapItem ? mapItem[0] : null;
  };
  const getTokenDecimals = (symbol: string): number => {
    const mapItem = (symbols || []).find(([p, s]) => s.symbol === symbol);
    if (!mapItem) {
      throw new Error('Unknown token');
    }
    return mapItem[1].decimals;
  };
  const getQuoteDecimals = (): number => {
    const mapItem = (symbols || []).find(([p]) => p.toText() === quoteLedger?.toText());
    return mapItem ? mapItem[1].decimals : 0;
  };

  useEffect(() => {
    if (!isOpen) return;
    resetApi();
    if (editLedger) {
      const mapItem = (symbols || []).find(([p]) => p.toText() === editLedger.toText());
      const symbol = mapItem ? mapItem[1].symbol : '';
      const mappedRows: OrderRow[] = editOrders && editOrders.length > 0
        ? editOrders.map(o => ({ kind: o.kind as 'ask' | 'bid', volume: o.volume.toString(), price: o.price.toString() }))
        : [{ kind: 'bid', volume: '', price: '' }];
      reset({ symbol, rows: mappedRows });
    } else {
      reset(defaultValues);
    }
  }, [isOpen, editLedger, symbols, editOrders]);

  const submit = (data: FormValues) => {
    const ledger = getLedgerPrincipal(data.symbol);
    if (!ledger) return;
    const decimals = getTokenDecimals(data.symbol);
    const qd = getQuoteDecimals();
    const orders = data.rows.map(r => ({
      kind: r.kind,
      volume: Math.round(Number(r.volume) * Math.pow(10, decimals)),
      price: Number(r.price) * Math.pow(10, qd - decimals),
    }));
    manage({ ledger, orders }, { onSuccess: () => onClose() });
  };

  const addRow = () => {
    reset({
      symbol: watch('symbol'),
      rows: [...(rows || []), { kind: 'bid', volume: '', price: '' }],
    });
  };

  const removeRow = (idx: number) => {
    const next = [...rows];
    next.splice(idx, 1);
    reset({ symbol: watch('symbol'), rows: next });
  };

  return (
    <Modal open={isOpen} onClose={onClose}>
      <ModalDialog sx={{ width: 800 }}>
        <ModalClose />
        <Typography id="dark-orders-title" component="h2" level="h4">
          {editLedger ? 'Edit dark order book' : 'Set dark order book'}
        </Typography>

        <form onSubmit={handleSubmit(submit)}>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
            <FormControl>
              <FormLabel>Token symbol</FormLabel>
              <Controller
                control={control}
                name="symbol"
                render={({ field }) => (
                  <Select
                    value={field.value ?? null}
                    onChange={(_, value) => field.onChange(value)}
                    onBlur={field.onBlur}
                    name={field.name}
                    disabled={!!editLedger}
                    placeholder="Select token"
                  >
                    {(symbols || [])
                      .filter(([p, s]) => p.toText() !== (quoteLedger?.toText() || ''))
                      .map(([p, s]) => (
                        <Option key={p.toText()} value={s.symbol}>
                          {s.symbol}
                        </Option>
                      ))}
                  </Select>
                )}
              />
            </FormControl>

            {(rows || []).map((row, i) => (
              <Box key={i} sx={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr auto', gap: 1, alignItems: 'end' }}>
                <FormControl>
                  <FormLabel>Kind</FormLabel>
                  <Controller
                    control={control}
                    name={`rows.${i}.kind` as any}
                    render={({ field }) => (
                      <RadioGroup {...field} orientation="horizontal">
                        <Radio value="bid" label="Bid" />
                        <Radio value="ask" label="Ask" />
                      </RadioGroup>
                    )}
                  />
                </FormControl>

                <FormControl>
                  <FormLabel>Volume</FormLabel>
                  <Controller control={control} name={`rows.${i}.volume` as any} render={({ field }) => <Input {...field} />} />
                </FormControl>

                <FormControl>
                  <FormLabel>Price</FormLabel>
                  <Controller control={control} name={`rows.${i}.price` as any} render={({ field }) => <Input {...field} />} />
                </FormControl>

                <Button variant="outlined" color="danger" onClick={() => removeRow(i)} disabled={(rows || []).length <= 1}>
                  Remove
                </Button>
              </Box>
            ))}

            <Box>
              <Button variant="outlined" onClick={addRow}>Add order</Button>
            </Box>

            {!!error && <ErrorAlert errorMessage={(error as Error).message} />}

            <Box sx={{ display: 'flex', justifyContent: 'flex-end', gap: 1 }}>
              <Button type="button" variant="outlined" onClick={onClose}>
                Cancel
              </Button>
              <Button type="submit" loading={isLoading}>
                Save
              </Button>
            </Box>
          </Box>
        </form>
      </ModalDialog>
    </Modal>
  );
};

export default DarkOrdersModal;
