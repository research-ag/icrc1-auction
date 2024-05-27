import { extendTheme, ThemeConfig } from '@chakra-ui/react'
import { mode } from '@chakra-ui/theme-tools'

interface ThemeProps {
  theme: ThemeConfig & { breakpoints?: Record<string, string> }
}

const theme = extendTheme({
  config: {
    initialColorMode: 'dark',
    useSystemColorMode: false,
  },
  fonts: {
    heading: 'var(--font-opensans)',
    body: 'var(--font-opensans)',
  },
  colors: {
    btn: {
      400: '#00E0C6',
      500: '#009987',
    },
    blue: {
      '50': '#edf8ff',
      '100': '#d6edff',
      '200': '#b5e1ff',
      '300': '#83d0ff',
      '400': '#48b5ff',
      '500': '#1e91ff',
      '600': '#0670ff',
      '700': '#005afa',
      '800': '#0847c5',
      '900': '#0d409b',
    },
    grey: {
      '25': '#FAFAFA',
      '50': '#F5F5F5',
      '100': '#E6E6E6',
      '200': '#D9D9D9',
      '250': '#BBBBBB',
      '300': '#A8A8A8',
      '400': '#939393',
      '450': '#7a7a7a',
      '500': '#696969',
      '600': '#545454',
      '700': '#434343',
      '800': '#292929',
      '900': '#141414',
    },
    yellow: {
      '50': '#FDFDF6',
      '100': '#F9F8E1',
      '200': '#F2F0BB',
      '300': '#EAE894',
      '400': '#E3DF6E',
      '500': '#DCD649',
      '600': '#C5BF26',
      '700': '#96921D',
      '800': '#626013',
      '900': '#33320A',
    },
    red: {
      '50': '#fff0f0',
      '100': '#ffdddd',
      '200': '#ffc0c0',
      '300': '#ff9494',
      '400': '#ff5757',
      '500': '#B81C1C',
      '600': '#991b1b',
      '700': '#7f1d1d',
      '800': '#681818',
      '900': '#5c1414',
    },
  },
  styles: {
    global: (props: ThemeProps) => ({
      body: {
        bg: mode('gray.900', 'white')(props),
        color: mode('white', 'gray.800')(props),
      },
      '&::-webkit-scrollbar': {
        width: '12px',
      },
      '&::-webkit-scrollbar-track': {
        width: '12px',
        background: mode('grey.800', 'grey.200')(props),
      },
      '&::-webkit-scrollbar-thumb': {
        background: mode('grey.700', 'grey.400')(props),
        borderRadius: '24px',
      },
    }),
  },
})

export default theme
