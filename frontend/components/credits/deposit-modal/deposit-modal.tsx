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
import {
  useAuctionCanisterId,
  useBtcAddress,
  useBtcNotify,
  useDeposit,
  useNotify,
  usePrincipalToSubaccount,
  useTokenInfoMap,
} from '@fe/integration';
import { Principal } from '@dfinity/principal';
import { useIdentity } from '@fe/integration/identity';
import { decodeIcrcAccount } from '@dfinity/ledger-icrc';
import { useSnackbar } from 'notistack';

interface DepositFormValues {
  symbol: string;
}

interface AllowanceFormValues {
  symbol: string;
  amount: number;
  account: string;
}

interface AddModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const schema = zod.object({
  symbol: zod
    .string()
    .min(1),
});

export const validateICRC1Account = (value: string): boolean => {
  try {
    decodeIcrcAccount(value);
    return true;
  } catch (e) {
    return false;
  }
};


const allowanceSchema = zod.object({
  symbol: zod
    .string()
    .min(1),
  amount: zod
    .string()
    .min(1)
    .refine(value => !isNaN(Number(value))),
  account: zod
    .string()
    .min(1)
    .refine(value => validateICRC1Account(value)),
});

const DepositModal = ({ isOpen, onClose }: AddModalProps) => {
  const defaultValues: DepositFormValues = useMemo(
    () => ({
      symbol: '',
    }),
    [],
  );

  const defaultAllowanceValues: AllowanceFormValues = useMemo(
    () => ({
      symbol: '',
      amount: 0,
      account: '',
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

  const { isDirty, isValid } = useFormState({ control });

  const { isDirty: isAllowanceDirty, isValid: isAllowanceValid } = useFormState({ control: allowanceControl });

  const { mutate: notify, error, isLoading, reset: resetApi } = useNotify();

  const {
    mutate: deposit,
    error: allowanceError,
    isLoading: isAllowanceLoading,
    reset: resetAllowanceApi,
  } = useDeposit();

  const { data: symbols } = useTokenInfoMap();
  const getLedgerPrincipal = (symbol: string): Principal | null => {
    const mapItem = (symbols || []).find(([p, s]) => s.symbol === symbol);
    return mapItem ? mapItem[0] : null;
  };
  const { enqueueSnackbar } = useSnackbar();

  const submit: SubmitHandler<DepositFormValues> = ({ symbol }) => {
    const p = getLedgerPrincipal(symbol);
    if (!p) {
      enqueueSnackbar(`Unknown token symbol: "${symbol}"`, { variant: 'error' });
      return;
    }
    notify(p, {
      onSuccess: () => {
        onClose();
      },
    });
  };

  const submitAllowance: SubmitHandler<AllowanceFormValues> = ({ symbol, amount, account }) => {
    let icrc1Account = decodeIcrcAccount(account);
    const p = getLedgerPrincipal(symbol);
    if (!p) {
      enqueueSnackbar(`Unknown token symbol: "${symbol}"`, { variant: 'error' });
      return;
    }
    deposit({
      token: p,
      amount,
      owner: icrc1Account.owner,
      subaccount: icrc1Account.subaccount || null,
    }, {
      onSuccess: () => {
        onClose();
      },
    });
  };

  const { mutate: btcSubmit, isLoading: isBtcLoading } = useBtcNotify();

  useEffect(() => {
    resetForm(defaultValues);
    resetApi();
    resetAllowanceForm(defaultAllowanceValues);
    resetAllowanceApi();
  }, [isOpen]);

  const { identity } = useIdentity();
  const subaccount = usePrincipalToSubaccount(identity.getPrincipal());
  const btcAddr = useBtcAddress(identity.getPrincipal());

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

  const auctionId = useAuctionCanisterId();

  return (
    <Modal open={isOpen} onClose={onClose}>
      <ModalDialog sx={{ width: 'calc(100% - 50px)', maxWidth: '450px' }}>
        <Tabs
          sx={{ backgroundColor: 'transparent' }}
          value={tabValue}
          onChange={(_, value) => setTabValue(value as number)}>
          <ModalClose/>
          <Typography level="h4">Deposit</Typography>
          <TabList sx={{ marginRight: 1, flexGrow: 1 }} style={{ margin: '16px 0' }} variant="plain">
            <Tab color="neutral">Transfer</Tab>
            <Tab color="neutral">Allowance</Tab>
            <Tab color="neutral">BTC direct</Tab>
          </TabList>

          {tabValue === 0 &&
              <div style={{ display: 'contents' }}>
                  <Typography level="body-xs">
                      1. Find out ICRC1 ledger principal to be used
                      <br/>
                      2. Make a transfer to account <b>{auctionId}</b>, subaccount{' '}
                      <b>{subaccountToText(subaccount.data)}</b> using ledger API
                      <br/>
                      3. Put token symbol in the input below and click "Notify"
                      <br/>
                  </Typography>
                  <form onSubmit={handleSubmit(submit)} autoComplete="off">
                      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
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
                              )}/>
                      </Box>
                    {!!error && <ErrorAlert errorMessage={(error as Error).message}/>}
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
                              name="symbol"
                              control={allowanceControl}
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
                              )}/>
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
                              )}/>
                          <Controller
                              name="account"
                              control={allowanceControl}
                              render={({ field, fieldState }) => (
                                <FormControl>
                                  <FormLabel>Account</FormLabel>
                                  <Typography level="body-xs">
                                    Type encoded ICRC-1 account
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
                              )}/>
                      </Box>
                    {!!allowanceError && <ErrorAlert errorMessage={(allowanceError as Error).message}/>}
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

          {tabValue === 2 &&
              <div style={{ display: 'contents' }}>
                  <Typography level="body-xs">
                      1. Transfer BTC to this address:
                      <br/>
                      <b>{btcAddr.data || '...loading...'}</b>
                      <br/>
                      2. Click "Notify"
                      <br/>
                  </Typography>
                  <Button
                      sx={{ marginTop: 2 }}
                      variant="solid"
                      onClick={() => btcSubmit()}
                      loading={isBtcLoading}>
                      Notify
                  </Button>
              </div>}

        </Tabs>
      </ModalDialog>
    </Modal>
  );
};

export default DepositModal;
