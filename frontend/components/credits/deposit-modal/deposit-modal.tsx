import { useEffect, useMemo, useState } from 'react';
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
    Tab,
    TabList,
    Tabs,
    Typography,
} from '@mui/joy';
import ErrorAlert from '../../error-alert';
import { useDeposit, useNotify, usePrincipalToSubaccount } from '@fe/integration';
import { validatePrincipal } from '@fe/utils';
import { Principal } from '@dfinity/principal';
import { useIdentity } from '@fe/integration/identity';
import { canisterId } from '@declarations/icrc1_auction';

interface DepositFormValues {
    icrc1Ledger: string;
}

interface AllowanceFormValues {
    icrc1Ledger: string;
    amount: number;
    subaccount: string;
}

interface AddModalProps {
    isOpen: boolean;
    onClose: () => void;
}

const schema = zod.object({
    icrc1Ledger: zod
      .string()
      .min(1)
      .refine(value => validatePrincipal(value)),
});

const allowanceSchema = zod.object({
    icrc1Ledger: zod
      .string()
      .min(1)
      .refine(value => validatePrincipal(value)),
    amount: zod
      .string()
      .min(1)
      .refine(value => !isNaN(Number(value))),
    subaccount: zod
      .string()
      .transform(value => value.replaceAll(' ', ''))
      .refine(value => value.length === 0 || value.length === 64),
});

const DepositModal = ({isOpen, onClose}: AddModalProps) => {
    const defaultValues: DepositFormValues = useMemo(
        () => ({
            icrc1Ledger: '',
        }),
        [],
    );

    const defaultAllowanceValues: AllowanceFormValues = useMemo(
      () => ({
          icrc1Ledger: '',
          amount: 0,
          subaccount: '',
      }),
      [],
    );

    const {
        handleSubmit,
        control,
        reset: resetForm,
    } = useForm<AllowanceFormValues>({
        defaultValues,
        resolver: zodResolver(schema),
        mode: 'onChange',
    });

    const {
        handleSubmit: handleAllowanceSubmit,
        control: allowanceControl,
        reset: resetAllowanceForm,
    } = useForm<AllowanceFormValues>({
        defaultValues: defaultAllowanceValues,
        resolver: zodResolver(allowanceSchema),
        mode: 'onChange',
    });

    const [tabValue, setTabValue] = useState(0);

    const {isDirty, isValid} = useFormState({control});

    const { isDirty: isAllowanceDirty, isValid: isAllowanceValid } = useFormState({ control: allowanceControl });

    const {mutate: notify, error, isLoading, reset: resetApi} = useNotify();

    const {
        mutate: deposit,
        error: allowanceError,
        isLoading: isAllowanceLoading,
        reset: resetAllowanceApi,
    } = useDeposit();

    const submit: SubmitHandler<DepositFormValues> = ({icrc1Ledger}) => {
        notify(Principal.fromText(icrc1Ledger), {
            onSuccess: () => {
                onClose();
            },
        });
    };

    const submitAllowance: SubmitHandler<AllowanceFormValues> = ({ icrc1Ledger, amount, subaccount }) => {
        let subaccountValue: number[] | null = subaccount.match(/.{2}/g)?.map(x => parseInt(x, 16)) || null;
        if (subaccountValue && subaccountValue.length !== 16) {
            subaccountValue = null;
        }
        deposit({
            token: Principal.fromText(icrc1Ledger),
            amount,
            subaccount: subaccountValue,
        }, {
            onSuccess: () => {
                onClose();
            },
        });
    };

    useEffect(() => {
        resetForm(defaultValues);
        resetApi();
        resetAllowanceForm(defaultAllowanceValues);
        resetAllowanceApi();
    }, [isOpen]);

    const {identity} = useIdentity();
    const subaccount = usePrincipalToSubaccount(identity.getPrincipal());

    const subaccountToText = (subaccount: [] | [Uint8Array | number[]] | undefined) => {
        if (!subaccount || !subaccount[0]) return '';
        return (
            '[0x' +
            Array.from(subaccount[0])
                .map(x => (x < 16 ? '0' : '') + x.toString(16))
                .join(' ') +
            ']'
        );
    };

    return (
        <Modal open={isOpen} onClose={onClose}>
            <ModalDialog sx={{width: 'calc(100% - 50px)', maxWidth: '450px'}}>
                <Tabs
                  sx={{ backgroundColor: 'transparent' }}
                  value={tabValue}
                  onChange={(_, value) => setTabValue(value as number)}>
                    <ModalClose />
                    <Typography level="h4">Deposit</Typography>
                    <TabList sx={{ marginRight: 1, flexGrow: 1 }} style={{ margin: '16px 0' }} variant="plain">
                        <Tab color="neutral">Transfer</Tab>
                        <Tab color="neutral">Allowance</Tab>
                    </TabList>

                    {tabValue === 0 &&
                      <div style={{ display: 'contents' }}>
                          <Typography level="body-xs">
                              1. Find out ICRC1 ledger principal to be used
                              <br />
                              2. Make a transfer to account <b>{canisterId}</b>, subaccount{' '}
                              <b>{subaccountToText(subaccount.data)}</b> using ledger API
                              <br />
                              3. Put ICRC1 ledger principal in the input below and click "Notify"
                              <br />
                          </Typography>
                          <form onSubmit={handleSubmit(submit)} autoComplete="off">
                              <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                                  <Controller
                                    name="icrc1Ledger"
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
                                    )} />
                              </Box>
                              {!!error && <ErrorAlert errorMessage={(error as Error).message} />}
                              <Button
                                sx={{ marginTop: 2 }}
                                variant="solid"
                                loading={isLoading}
                                type="submit"
                                disabled={!isValid || !isDirty}>
                                  Notify
                              </Button>
                          </form>
                      </div>}

                    {tabValue === 1 &&
                      <div style={{ display: 'contents' }}>
                          <form onSubmit={handleAllowanceSubmit(submitAllowance)} autoComplete="off">
                              <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                                  <Controller
                                    name="icrc1Ledger"
                                    control={allowanceControl}
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
                                    )} />
                                  <Controller
                                    name="amount"
                                    control={allowanceControl}
                                    render={({ field, fieldState }) => (
                                      <FormControl>
                                          <FormLabel>Amount</FormLabel>
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
                                    )} />
                                  <Controller
                                    name="subaccount"
                                    control={allowanceControl}
                                    render={({ field, fieldState }) => (
                                      <FormControl>
                                          <FormLabel>Subaccount</FormLabel>
                                          <Typography level="body-xs">
                                              Paste hex string, exactly 64 characters or leave empty to use subaccount
                                              null. Spaces will be ignored
                                          </Typography>
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
                                    )} />
                              </Box>
                              {!!allowanceError && <ErrorAlert errorMessage={(allowanceError as Error).message} />}
                              <Button
                                sx={{ marginTop: 2 }}
                                variant="solid"
                                loading={isAllowanceLoading}
                                type="submit"
                                disabled={!isAllowanceValid || !isAllowanceDirty}>
                                  Deposit
                              </Button>
                          </form>
                      </div>}

                </Tabs>
            </ModalDialog>
        </Modal>
    );
};

export default DepositModal;
