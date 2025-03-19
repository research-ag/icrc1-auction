import { useEffect, useMemo } from 'react';
import { Controller, SubmitHandler, useForm, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
import { Box, Button, FormControl, FormLabel, Input, Modal, ModalClose, ModalDialog, Typography } from '@mui/joy';

import { useWithdrawCycles } from '@fe/integration';
import ErrorAlert from '../../../components/error-alert';
import { validatePrincipal } from "@fe/utils";

interface WithdrawCyclesFormValues {
  amount: number;
  to: string;
}

interface WithdrawCyclesModalProps {
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
    .refine(value => value === '' || validatePrincipal(value)),
});

const WithdrawCyclesModal = ({ isOpen, onClose }: WithdrawCyclesModalProps) => {
  const defaultValues: WithdrawCyclesFormValues = useMemo(
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
  } = useForm<WithdrawCyclesFormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const { isDirty, isValid } = useFormState({ control });

  const { mutate: withdraw, error, isLoading, reset: resetApi } = useWithdrawCycles();


  const submit: SubmitHandler<WithdrawCyclesFormValues> = data => {
    withdraw(
      { to: data.to, amount: Math.round(data.amount * Math.pow(10, 12)) },
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
        <Typography level="h4">Withdraw cycles directly</Typography>
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
                  <FormLabel>Canister principal</FormLabel>
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
            Withdraw cycles
          </Button>
        </form>
      </ModalDialog>
    </Modal>
  );
};

export default WithdrawCyclesModal;
