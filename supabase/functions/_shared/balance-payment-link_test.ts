import { assertEquals, assertFalse, assertThrows } from "jsr:@std/assert@1";
import { buildBalancePaymentUrl } from "./balance-payment-link.ts";

Deno.test("balance payment link keeps the secret in the fragment", () => {
  const token = "a".repeat(64);
  const url = buildBalancePaymentUrl(
    "https://www.blacksheepestudiocriativo.com.br/",
    token,
  );
  assertEquals(
    url,
    `https://www.blacksheepestudiocriativo.com.br/pagar-saldo#token=${token}`,
  );
  assertFalse(url.includes("?"));
});

Deno.test("balance payment link rejects non-HTTPS hosts and malformed tokens", () => {
  assertThrows(
    () => buildBalancePaymentUrl("http://example.test", "a".repeat(64)),
    Error,
    "PUBLIC_BOOKING_BASE_URL_INVALID",
  );
  assertThrows(
    () => buildBalancePaymentUrl("https://example.test", "short"),
    Error,
    "BALANCE_PAYMENT_TOKEN_INVALID",
  );
});
