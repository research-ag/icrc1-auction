import { useEffect, useMemo } from 'react';
import { Controller, SubmitHandler, useForm, useFormState } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z as zod } from 'zod';
import { Box, Button, FormControl, FormLabel, Input, Modal, ModalClose, ModalDialog, Typography } from '@mui/joy';

import { useAddAsset } from '../../integration';
import ErrorAlert from '../../components/error-alert';
import { Principal } from '@dfinity/principal';
import { validatePrincipal } from '../../utils';

interface AddFormValues {
  principal: string;
  minAskVolume: number;
}

interface AddModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const schema = zod.object({
  principal: zod
    .string()
    .min(1)
    .refine(value => validatePrincipal(value)),
  minAskVolume: zod
    .string()
    .min(0)
    .refine(value => !isNaN(Number(value))),
});

const AddAssetModal = ({ isOpen, onClose }: AddModalProps) => {
  const defaultValues: AddFormValues = useMemo(
    () => ({
      principal: '',
      minAskVolume: 0,
    }),
    [],
  );

  const {
    handleSubmit,
    control,
    reset: resetForm,
  } = useForm<AddFormValues>({
    defaultValues,
    resolver: zodResolver(schema),
    mode: 'onChange',
  });

  const { isDirty, isValid } = useFormState({ control });

  const { mutate: addAsset, error, isLoading, reset: resetApi } = useAddAsset();

  const submit: SubmitHandler<AddFormValues> = data => {
    addAsset(
      {
        principal: Principal.fromText(data.principal),
        minAskVolume: data.minAskVolume,
      },
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
        <Typography level="h4">Add asset</Typography>
        <form onSubmit={handleSubmit(submit)} autoComplete="off">
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <Controller
              name="principal"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Principal</FormLabel>
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
              name="minAskVolume"
              control={control}
              render={({ field, fieldState }) => (
                <FormControl>
                  <FormLabel>Min ask volume</FormLabel>
                  <Input
                    type="number"
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

export default AddAssetModal;
