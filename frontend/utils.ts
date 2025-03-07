import { Principal } from '@dfinity/principal';

export const validatePrincipal = (value: string): boolean => {
  try {
    Principal.from(value);
    return true;
  } catch (e) {
    return false;
  }
};

// convert number to string avoiding scientific notation
const numberToString = (num: number): string => {
  let numStr = String(num);
  if (Math.abs(num) < 1.0) {
    let e = parseInt(num.toString().split('e-')[1]);
    if (e) {
      let negative = num < 0;
      if (negative) num *= -1
      num *= Math.pow(10, e - 1);
      numStr = '0.' + (new Array(e)).join('0') + num.toString().substring(2);
      if (negative) numStr = "-" + numStr;
    }
  } else {
    let e = parseInt(num.toString().split('+')[1]);
    if (e > 20)
    {
      e -= 20;
      num /= Math.pow(10, e);
      numStr = num.toString() + (new Array(e + 1)).join('0');
    }
  }
  return numStr;
}

// string-based decimal point transformation
export const displayWithDecimals = (value: bigint | number, decimals: number, maxSignificantDigits: number = 0): string => {
  if (value < 0) {
    throw new Error('Wrong natural number provided: ' + value.toString());
  }
  let res = numberToString(Number(value));
  if (decimals === 0) {
    return res;
  }
  let [intPart, fracPart] = res.split('.');
  fracPart = fracPart || '';
  while (decimals < 0) {
    if (fracPart == '') {
      intPart += '0';
    } else {
      intPart += fracPart[0];
      fracPart = fracPart.slice(1);
    }
    decimals++;
  }
  while (decimals > 0) {
    if (intPart == '') {
      fracPart = '0' + fracPart;
    } else {
      fracPart = intPart[intPart.length - 1] + fracPart;
      intPart = intPart.slice(0, intPart.length - 1);
    }
    decimals--;
  }
  intPart = intPart.replace(/^0+/, '');
  if (maxSignificantDigits > 0) {
    let maxFracPartLength = Math.max(0, maxSignificantDigits - intPart.length);
    let fracSignificantPart = intPart.length ? fracPart : fracPart.replace(/^0+/, '');
    if (fracSignificantPart.length > maxFracPartLength) {
      const fracFullLength = (fracPart.length - fracSignificantPart.length) + maxFracPartLength;
      fracPart = (parseFloat('0.' + fracPart)).toFixed(fracFullLength).slice(2);
    }
  }
  fracPart = fracPart.replace(/0+$/, '');
  res = intPart || "0";
  if (fracPart) {
    res += "." + fracPart;
  }
  return res;
};

export const subaccountToText = (subaccount: [] | [Uint8Array | number[]] | undefined) => {
  if (!subaccount || !subaccount[0]) return 'null';
  return (
    '[0x' +
    Array.from(subaccount[0])
      .map(x => (x < 16 ? '0' : '') + x.toString(16))
      .join(' ') +
    ']'
  );
};
