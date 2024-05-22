import { useEffect, useMemo } from 'react';
import { useForm, SubmitHandler, Controller, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
import { Box, Modal, ModalDialog, ModalClose, FormControl, FormLabel, Input, Typography, Button } from '@mui/joy';

import { usePlaceOrder } from '../../../integration';
import ErrorAlert from '../../../components/error-alert';
import { validatePrincipal } from '../../../utils';

interface PlaceOrderFormValues {
  ledger: string;
  volume: number;
  price: number;
}

interface PlaceOrderModalProps {
  kind: 'bid' | 'ask';
  isOpen: boolean;
  onClose: () => void;
}

const schema = zod.object({
  ledger: zod
    .string()
    .min(1)
    .refine(value => validatePrincipal(value)),
  volume: zod
    .string()
    .min(1)
    .refine(value => !isNaN(Number(value))),
  price: zod
    .string()
    .min(1)
    .refine(value => !isNaN(Number(value))),
});

const PlaceOrderModal = ({ kind, isOpen, onClose }: PlaceOrderModalProps) => {
  const defaultValues: PlaceOrderFormValues = useMemo(
    () => ({
      ledger: '',
      volume: 0,
      price: 0,
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

  const submit: SubmitHandler<PlaceOrderFormValues> = data => {
    placeOrder(data, {
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
        <ModalClose />
        <Typography level="h4">Place {kind}</Typography>
        <form onSubmit={handleSubmit(submit)} autoComplete="off">
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <Controller
              name="ledger"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Ledger principal</FormLabel>
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
          {!!error && <ErrorAlert errorMessage={(error as Error).message} />}
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
