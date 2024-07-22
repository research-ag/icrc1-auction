import { Principal } from '@dfinity/principal';

export const validatePrincipal = (value: string): boolean => {
  try {
    Principal.from(value);
    return true;
  } catch (e) {
    return false;
  }
};

export const displayWithDecimals = (value: bigint | number, decimals: number): string => {
  if (value < 0) {
    throw new Error('Wrong natural number provided: ' + value.toString());
  }
  let res = value.toString();
  if (decimals === 0) {
    return res;
  }
  if (decimals > 0) {
    if (res.length <= decimals) {
      res = '0.' + res.padStart(decimals, '0');
    } else {
      res = res.slice(0, res.length - decimals) + '.' + res.slice(res.length - decimals);
    }
    while (res[res.length - 1] === '0' && res[res.length - 2] !== '.') {
      res = res.slice(0, res.length - 1);
    }
  } else if (res !== '0') {
    res = res.padEnd(res.length - decimals, '0');
  }
  return res;
};
