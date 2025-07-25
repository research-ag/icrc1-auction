import { useEffect, useMemo } from 'react';
import { Controller, SubmitHandler, useForm, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
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
  Typography
} from '@mui/joy';

import { usePlaceOrder, useQuoteLedger, useTokenInfoMap } from '@fe/integration';
import ErrorAlert from '../../../components/error-alert';
import { Principal } from '@dfinity/principal';
import { useSnackbar } from 'notistack';

interface PlaceOrderFormValues {
  symbol: string;
  volume: number;
  price: number;
  orderBookType: 'immediate' | 'delayed';
}

interface PlaceOrderModalProps {
  kind: 'bid' | 'ask';
  isOpen: boolean;
  onClose: () => void;
}

const schema = zod.object({
  symbol: zod
    .string()
    .min(1),
  volume: zod
    .string()
    .min(0)
    .refine(value => !isNaN(Number(value))),
  price: zod
    .string()
    .min(0)
    .refine(value => !isNaN(Number(value))),
  orderBookType: zod.enum(['immediate', 'delayed']),
});

const PlaceOrderModal = ({ kind, isOpen, onClose }: PlaceOrderModalProps) => {
  const defaultValues: PlaceOrderFormValues = useMemo(
    () => ({
      symbol: '',
      volume: 0,
      price: 0,
      orderBookType: 'delayed',
    }),
    [],
  );

  const {
    handleSubmit,
    control,
    reset: resetForm,
  } = useForm<PlaceOrderFormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const { isDirty, isValid } = useFormState({ control });

  const { mutate: placeOrder, error, isLoading, reset: resetApi } = usePlaceOrder(kind);

  const { data: symbols } = useTokenInfoMap();
  const { data: quoteLedger } = useQuoteLedger();
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
  const { enqueueSnackbar } = useSnackbar();

  const submit: SubmitHandler<PlaceOrderFormValues> = data => {
    const p = getLedgerPrincipal(data.symbol);
    if (!p) {
      enqueueSnackbar(`Unknown token symbol: "${data.symbol}"`, { variant: 'error' });
      return;
    }
    let decimals = getTokenDecimals(data.symbol);
    placeOrder({
      ledger: p.toText(),
      price: data.price * Math.pow(10, getQuoteDecimals() - decimals),
      volume: Math.round(data.volume * Math.pow(10, decimals)),
      orderBookType: data.orderBookType,
    }, {
      onSuccess: () => {
        onClose();
      },
    });
  };

  useEffect(() => {
    resetForm(defaultValues);
    resetApi();
  }, [isOpen]);

  return (
    <Modal open={isOpen} onClose={onClose}>
      <ModalDialog sx={{ width: 'calc(100% - 50px)', maxWidth: '450px' }}>
        <ModalClose/>
        <Typography level="h4">Place {kind}</Typography>
        <form onSubmit={handleSubmit(submit)} autoComplete="off">
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <Controller
              name="orderBookType"
              control={control}
              render={({ field }) => (
                <FormControl>
                  <FormLabel>Order Book Type</FormLabel>
                  <RadioGroup
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}>
                    <Radio value="delayed" label="Delayed"/>
                    <Radio value="immediate" label="Immediate"/>
                  </RadioGroup>
                </FormControl>
              )}
            />
            <Controller
              name="symbol"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Token symbol</FormLabel>
                  <Input
                    type="text"
                    variant="outlined"
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}
                    autoComplete="off"
                    error={!!fieldState.error}
                  />
                </FormControl>
              )}
            />
            <Controller
              name="volume"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Volume</FormLabel>
                  <Input
                    type="text"
                    variant="outlined"
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}
                    autoComplete="off"
                    error={!!fieldState.error}
                  />
                </FormControl>
              )}
            />
            <Controller
              name="price"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Price</FormLabel>
                  <Input
                    type="text"
                    variant="outlined"
                    name={field.name}
                    value={field.value}
                    onChange={field.onChange}
                    autoComplete="off"
                    error={!!fieldState.error}
                  />
                </FormControl>
              )}
            />
          </Box>
          {!!error && <ErrorAlert errorMessage={(error as Error).message}/>}
          <Button
            sx={{ marginTop: 2 }}
            variant="solid"
            loading={isLoading}
            type="submit"
            disabled={!isValid || !isDirty}>
            Add
          </Button>
        </form>
      </ModalDialog>
    </Modal>
  );
};

export default PlaceOrderModal;
