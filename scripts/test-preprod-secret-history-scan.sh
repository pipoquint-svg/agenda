#!/usr/bin/env bash
set -euo pipefail

source scripts/preprod-secret-history-scan.sh

expect_classified() {
  local pattern_index="$1"
  local path="$2"
  local content="$3"
  if ! grep -Eq "${patterns[$pattern_index]}" <<<"$content"; then
    echo "Fixture does not exercise pattern $pattern_index: $path" >&2
    exit 1
  fi
  if ! classify_intentional_non_secret "$pattern_index" "$path" "$content"; then
    echo "Expected synthetic fixture to be classified: $path" >&2
    exit 1
  fi
  if [[ "$CLASSIFICATION_KIND" != 'local_synthetic' ]]; then
    echo "Unexpected classification kind for $path: $CLASSIFICATION_KIND" >&2
    exit 1
  fi
}

expect_candidate() {
  local pattern_index="$1"
  local path="$2"
  local content="$3"
  if ! grep -Eq "${patterns[$pattern_index]}" <<<"$content"; then
    echo "Negative control does not exercise pattern $pattern_index: $path" >&2
    exit 1
  fi
  if classify_intentional_non_secret "$pattern_index" "$path" "$content"; then
    echo "Dangerous candidate was incorrectly classified as safe: $path ($CLASSIFICATION_KIND)" >&2
    exit 1
  fi
}

# Reconstruct historical synthetic lines at runtime. No provider-shaped credential
# is stored as one literal string in this test file.
google_guard_fixture="expect_reject google_secret 'GOOGLE_CLIENT_SECRET="
google_guard_fixture+="$synthetic_google_token"
google_guard_fixture+="'"
mp_guard_fixture="expect_reject mp_token 'MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN="
mp_guard_fixture+="$synthetic_mp_token"
mp_guard_fixture+="'"
google_test_fixture="GOOGLE_CLIENT_SECRET: '"
google_test_fixture+="$synthetic_google_token"
google_test_fixture+="',"

expect_classified 5 'scripts/test-local-verification-safety.sh' "$google_guard_fixture"
expect_classified 9 'scripts/test-local-verification-safety.sh' "$mp_guard_fixture"
expect_classified 9 'supabase/functions/_shared/local-verification_test.ts' "$google_test_fixture"

local_access_fixture='MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN='
local_access_fixture+='LOCAL_ONLY_do_not_use'
local_webhook_fixture="MERCADO_PAGO_WEBHOOK_SECRET: '"
local_webhook_fixture+='LOCAL_ONLY_webhook_secret'
local_webhook_fixture+="',"
expect_classified 9 'supabase/functions/.env.local-verification.example' "$local_access_fixture"
expect_classified 9 'supabase/functions/_shared/local-verification_test.ts' "$local_webhook_fixture"

local_reader_fixture='const SERVICE_ROLE_KEY = '
local_reader_fixture+="requiredEnv('LOCAL_SERVICE_ROLE_KEY')"
expect_classified 9 'tests/local-verification/item01_e2e_test.ts' "$local_reader_fixture"
expect_classified 9 'tests/local-verification/item02a_google_worker_test.ts' "$local_reader_fixture"

# Negative controls are also assembled at runtime so the scanner can inspect this test
# file without mistaking the controls themselves for committed credentials.
mp_private_candidate='MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN='
mp_private_candidate+='APP_'
mp_private_candidate+='USR-abcdefghijklmnopqrstuvwxyz1234567890'
expect_candidate 0 'supabase/functions/payment/index.ts' "$mp_private_candidate"

google_private_candidate='GOOGLE_CLIENT_SECRET='
google_private_candidate+='GOC'
google_private_candidate+='SPX-abcdefghijklmnopqrstuvwxyz123456'
expect_candidate 5 'supabase/functions/google-oauth/index.ts' "$google_private_candidate"

service_role_candidate='SERVICE_ROLE_KEY='
service_role_candidate+='abcdefghijklmnop1234567890'
expect_candidate 9 'supabase/functions/payment/index.ts' "$service_role_candidate"

client_secret_candidate='CLIENT_SECRET='
client_secret_candidate+='abcdefghijklmnopqrstuvwxyz123456'
expect_candidate 9 'supabase/functions/google-oauth/index.ts' "$client_secret_candidate"

wrong_local_candidate='SERVICE_ROLE_KEY='
wrong_local_candidate+='LOCAL_ONLY_but_wrong_context'
expect_candidate 9 'supabase/functions/payment/index.ts' "$wrong_local_candidate"

wrong_google_sentinel='GOOGLE_CLIENT_SECRET='
wrong_google_sentinel+="$synthetic_google_token"
expect_candidate 5 'supabase/functions/google-oauth/index.ts' "$wrong_google_sentinel"

echo 'historical secret classification tests: ok'
