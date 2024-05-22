import { useEffect, useMemo } from 'react';
import { Controller, SubmitHandler, useForm, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
import { Box, Button, FormControl, FormLabel, Input, Modal, ModalClose, ModalDialog, Typography } from '@mui/joy';

import { useWithdrawCredit } from '../../../integration';
import ErrorAlert from '../../../components/error-alert';
import { enqueueSnackbar } from 'notistack';

interface WithdrawCreditFormValues {
  amount: number;
  subaccount: string;
}

interface WithdrawCreditModalProps {
  isOpen: boolean;
  onClose: () => void;
  ledger: string;
}

const schema = zod.object({
  amount: zod
    .string()
    .min(1)
    .refine(value => !isNaN(Number(value))),
  subaccount: zod.string(),
});

const WithdrawCreditModal = ({ isOpen, onClose, ledger }: WithdrawCreditModalProps) => {
  const defaultValues: WithdrawCreditFormValues = useMemo(
    () => ({
      amount: 0,
      subaccount: '',
    }),
    [],
  );

  const {
    handleSubmit,
    control,
    reset: resetForm,
  } = useForm<WithdrawCreditFormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const { isDirty, isValid } = useFormState({ control });

  const { mutate: withdraw, error, isLoading, reset: resetApi } = useWithdrawCredit();

  const submit: SubmitHandler<WithdrawCreditFormValues> = data => {
    let subaccountStr = data.subaccount.replace(/\s/g, '');
    if (subaccountStr.startsWith('0x')) {
      subaccountStr = subaccountStr.substring(2);
    }
    let subaccount: Uint8Array | null = null;
    if (subaccountStr.length > 0) {
      if (subaccountStr.length !== 64) {
        enqueueSnackbar(`Unknown subaccount format. Provide base16 string with length 32 bytes`, { variant: 'error' });
        return;
      }
      subaccount = new Uint8Array(32);
      for (let i = 0; i < 32; i++) {
        subaccount[i] = parseInt(subaccountStr.substring(i * 2, i * 2 + 2), 16);
      }
    }
    withdraw(
      { ledger, subaccount, amount: data.amount },
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
        <ModalClose />
        <Typography level="h4">Withdraw credit (ledger {ledger})</Typography>
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
              name="subaccount"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Base16 subaccount. Leave empty for null</FormLabel>
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
            Withdraw
          </Button>
        </form>
      </ModalDialog>
    </Modal>
  );
};

export default WithdrawCreditModal;
