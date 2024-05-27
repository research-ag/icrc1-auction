// eslint-disable-next-line @typescript-eslint/no-unused-vars
import React from 'react'

import { ChakraProvider } from '@chakra-ui/react'
import { createRoot } from 'react-dom/client'

import App from './app'
import theme from './theme'

const container = document.getElementById('root')
const root = createRoot(container!)
root.render(
  <ChakraProvider theme={theme}>
    <App />
  </ChakraProvider>,
)
