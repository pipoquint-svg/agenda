export function buildBalancePaymentUrl(
  baseUrl: string,
  accessToken: string,
): string {
  const normalizedBase = baseUrl.trim().replace(/\/$/, "");
  if (!/^https:\/\//i.test(normalizedBase)) {
    throw new Error("PUBLIC_BOOKING_BASE_URL_INVALID");
  }
  if (!/^[0-9a-f]{64}$/i.test(accessToken)) {
    throw new Error("BALANCE_PAYMENT_TOKEN_INVALID");
  }
  return `${normalizedBase}/pagar-saldo#token=${
    encodeURIComponent(accessToken)
  }`;
}
