import { QueryClient, QueryClientProvider } from 'react-query';
import { CssVarsProvider } from '@mui/joy/styles';
import { SnackbarProvider } from 'notistack';
import CssBaseline from '@mui/joy/CssBaseline';
import '@fontsource/inter';

import { IdentityProvider } from './integration/identity';
import Root from './components/root';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: false },
    mutations: { retry: false },
  },
});

const App = () => {
  return (
    <QueryClientProvider client={queryClient}>
      <CssVarsProvider defaultMode="light">
        <CssBaseline />
        <SnackbarProvider anchorOrigin={{ vertical: 'bottom', horizontal: 'right' }}>
          <IdentityProvider>
            <Root />
          </IdentityProvider>
        </SnackbarProvider>
      </CssVarsProvider>
    </QueryClientProvider>
  );
};

export default App;
