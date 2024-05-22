import {useEffect, useMemo} from 'react';
import {Controller, SubmitHandler, useForm, useFormState} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z as zod} from 'zod';
import {Box, Button, FormControl, FormLabel, Input, Modal, ModalClose, ModalDialog, Typography} from '@mui/joy';
import ErrorAlert from '../../error-alert';
import {useNotify, usePrincipalToSubaccount} from '../../../integration';
import {validatePrincipal} from '../../../utils';
import {Principal} from '@dfinity/principal';
import {useIdentity} from '../../../integration/identity';

interface DepositFormValues {
    icrc1Ledger: string;
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

const DepositModal = ({isOpen, onClose}: AddModalProps) => {
    const defaultValues: DepositFormValues = useMemo(
        () => ({
            icrc1Ledger: '',
        }),
        [],
    );

    const {
        handleSubmit,
        control,
        reset: resetForm,
    } = useForm<DepositFormValues>({
        defaultValues,
        resolver: zodResolver(schema),
        mode: 'onChange',
    });

    const {isDirty, isValid} = useFormState({control});

    const {mutate: notify, error, isLoading, reset: resetApi} = useNotify();

    const submit: SubmitHandler<DepositFormValues> = ({icrc1Ledger}) => {
        notify(Principal.fromText(icrc1Ledger), {
            onSuccess: () => {
                onClose();
            },
        });
    };

    useEffect(() => {
        resetForm(defaultValues);
        resetApi();
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
                <ModalClose/>
                <Typography level="h4">Deposit</Typography>
                <Typography level="body-xs">
                    1. Find out ICRC1 ledger principal to be used
                    <br/>
                    2. Make a transfer to account <b>{process.env.ICRC1_AUCTION_CANISTER_ID}</b>, subaccount{' '}
                    <b>{subaccountToText(subaccount.data)}</b> using ledger API
                    <br/>
                    3. Put ICRC1 ledger principal in the input below and click "Notify"
                    <br/>
                </Typography>
                <form onSubmit={handleSubmit(submit)} autoComplete="off">
                    <Box sx={{display: 'flex', flexDirection: 'column', gap: 1}}>
                        <Controller
                            name="icrc1Ledger"
                            control={control}
                            render={({field, fieldState}) => (
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
                    </Box>
                    {!!error && <ErrorAlert errorMessage={(error as Error).message}/>}
                    <Button
                        sx={{marginTop: 2}}
                        variant="solid"
                        loading={isLoading}
                        type="submit"
                        disabled={!isValid || !isDirty}>
                        Notify
                    </Button>
                </form>
            </ModalDialog>
        </Modal>
    );
};

export default DepositModal;
