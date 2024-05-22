import { Principal } from '@dfinity/principal';

export const validatePrincipal = (value: string): boolean => {
  try {
    Principal.from(value);
    return true;
  } catch (e) {
    return false;
  }
};
