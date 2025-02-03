import { useEffect, useMemo } from 'react';
import { Controller, SubmitHandler, useForm, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
import { Box, Button, FormControl, FormLabel, Input, Modal, ModalClose, ModalDialog, Typography } from '@mui/joy';

import { useWithdrawBtc } from '@fe/integration';
import ErrorAlert from '../../../components/error-alert';

interface WithdrawBtcFormValues {
  amount: number;
  to: string;
}

interface WithdrawBtcModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const schema = zod.object({
  amount: zod
    .string()
    .min(0)
    .refine(value => !isNaN(Number(value))),
  to: zod
    .string()
    .regex(/\b((bc|tb)(0([ac-hj-np-z02-9]{39}|[ac-hj-np-z02-9]{59})|1[ac-hj-np-z02-9]{8,87})|([13]|[mn2])[a-km-zA-HJ-NP-Z1-9]{25,39})\b/g),
});

const WithdrawBtcModal = ({ isOpen, onClose }: WithdrawBtcModalProps) => {
  const defaultValues: WithdrawBtcFormValues = useMemo(
    () => ({
      amount: 0,
      to: '',
    }),
    [],
  );

  const {
    handleSubmit,
    control,
    reset: resetForm,
  } = useForm<WithdrawBtcFormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const { isDirty, isValid } = useFormState({ control });

  const { mutate: withdraw, error, isLoading, reset: resetApi } = useWithdrawBtc();


  const submit: SubmitHandler<WithdrawBtcFormValues> = data => {
    withdraw(
      { address: data.to, amount: Math.round(data.amount * Math.pow(10, 8)) },
      {
        onSuccess: () => {
          onClose();
        },
      },
    );
  };

  useEffect(() => {
    resetForm(defaultValues);
    resetApi();
  }, [isOpen]);

  return (
    <Modal open={isOpen} onClose={onClose}>
      <ModalDialog sx={{ width: 'calc(100% - 50px)', maxWidth: '450px' }}>
        <ModalClose/>
        <Typography level="h4">Withdraw BTC directly</Typography>
        <form onSubmit={handleSubmit(submit)} autoComplete="off">
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <Controller
              name="amount"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Amount</FormLabel>
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
              name="to"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>BTC address</FormLabel>
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
            Withdraw BTC
          </Button>
        </form>
      </ModalDialog>
    </Modal>
  );
};

export default WithdrawBtcModal;
