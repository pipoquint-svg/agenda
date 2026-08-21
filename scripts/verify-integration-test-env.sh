#!/usr/bin/env bash
set -euo pipefail

fail() { echo "PRE-FLIGHT FALHOU: $*" >&2; exit 1; }
need() { local n="$1"; [[ -n "${!n:-}" ]] || fail "variavel obrigatoria ausente: $n"; }

need APP_ENV
[[ "$APP_ENV" == "test" || "$APP_ENV" == "staging" ]] || fail "APP_ENV deve ser test ou staging"

# Google: dedicated test project/account/calendars and durable auth strategy.
need GOOGLE_TEST_PROJECT_ID
need GOOGLE_TEST_ACCOUNT_EMAIL
need GOOGLE_TEST_CALENDAR_PREFIX
[[ "$GOOGLE_TEST_CALENDAR_PREFIX" == "TESTE"* ]] || fail "calendarios de teste devem usar prefixo TESTE"

need GOOGLE_AUTH_STRATEGY
case "$GOOGLE_AUTH_STRATEGY" in
  OAUTH_PUBLICADO|WORKSPACE_DELEGATION) ;;
  *) fail "GOOGLE_AUTH_STRATEGY deve ser OAUTH_PUBLICADO ou WORKSPACE_DELEGATION antes dos testes duraveis" ;;
esac

need GOOGLE_GRANTED_SCOPES
[[ "$GOOGLE_GRANTED_SCOPES" == *"https://www.googleapis.com/auth/calendar.events"* ]] || fail "scope de escrita calendar.events ausente"
[[ "$GOOGLE_GRANTED_SCOPES" == *"https://www.googleapis.com/auth/calendar.calendarlist.readonly"* ]] || fail "scope calendarlist.readonly ausente"

# Mercado Pago: do not infer sandbox safety from a token prefix. Require explicit
# sandbox declaration and a dedicated test user, then prove the provider flow in Gate 2/3.
need MERCADO_PAGO_ENV
[[ "$MERCADO_PAGO_ENV" == "sandbox" ]] || fail "Mercado Pago deve estar em sandbox"
need MERCADO_PAGO_ACCESS_TOKEN
need MERCADO_PAGO_TEST_USER_ID

# WhatsApp: explicit test mode and recipient allowlist.
need WHATSAPP_TEST_MODE
[[ "$WHATSAPP_TEST_MODE" == "true" ]] || fail "WhatsApp deve estar explicitamente em modo de teste"
need WHATSAPP_TEST_RECIPIENT_ALLOWLIST
[[ -n "$WHATSAPP_TEST_RECIPIENT_ALLOWLIST" ]] || fail "allowlist de destinatarios de teste vazia"

# Production references and side effects are forbidden in sandbox.
if [[ -n "${PRODUCTION_CALENDAR_IDS:-}" ]]; then
  fail "PRODUCTION_CALENDAR_IDS nao deve existir no ambiente de teste"
fi

if [[ "${ALLOW_REAL_CUSTOMER_DATA:-false}" == "true" ]]; then
  fail "dados reais de clientes sao proibidos no sandbox"
fi

if [[ "${ALLOW_REAL_CHARGES:-false}" == "true" ]]; then
  fail "cobrancas reais sao proibidas no sandbox"
fi

if [[ "${ALLOW_REAL_WHATSAPP_RECIPIENTS:-false}" == "true" ]]; then
  fail "destinatarios reais de WhatsApp sao proibidos no sandbox"
fi

echo "PRE-FLIGHT PASSOU: ambiente declarado como isolado."
echo "Google strategy: $GOOGLE_AUTH_STRATEGY"
echo "Google test project: $GOOGLE_TEST_PROJECT_ID"
echo "Google test account: $GOOGLE_TEST_ACCOUNT_EMAIL"
echo "Google calendar prefix: $GOOGLE_TEST_CALENDAR_PREFIX"
echo "Google write scope: presente"
echo "Mercado Pago: sandbox / test user declarado"
echo "WhatsApp: test mode / allowlist declarada"
