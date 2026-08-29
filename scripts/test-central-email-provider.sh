#!/usr/bin/env bash
set -euo pipefail

root='supabase/functions'
provider_file="$root/_shared/email-provider.ts"
provider_test_file="$root/_shared/email-provider_test.ts"

fail_matches() {
  local pattern="$1"
  local label="$2"
  local matches
  matches="$(grep -R -n -F --include='*.ts' "$pattern" "$root" 2>/dev/null \
    | grep -v -F "$provider_file" \
    | grep -v -F "$provider_test_file" \
    || true)"
  if [[ -n "$matches" ]]; then
    echo "EMAIL_PROVIDER_INVARIANT_FAILED: $label must exist only in $provider_file (tests may assert the contract in $provider_test_file)" >&2
    echo "$matches" >&2
    exit 1
  fi
}

fail_matches 'https://api.resend.com/emails' 'Resend API endpoint'
fail_matches "Deno.env.get('RESEND_API_KEY')" 'RESEND_API_KEY access'
fail_matches 'Deno.env.get("RESEND_API_KEY")' 'RESEND_API_KEY access'
fail_matches 'smtp.resend.com' 'SMTP provider host'

grep -Fq "return 'RESEND'" "$provider_file" || {
  echo 'EMAIL_PROVIDER_INVARIANT_FAILED: canonical provider must be RESEND' >&2
  exit 1
}

grep -Fq "sendEmailWithProvider" "$root/email-send/index.ts"
grep -Fq "sendEmailWithProvider" "$root/balance-collection-notify-email/index.ts"
grep -Fq "sendEmailWithProvider" "$root/birthday-email-worker/index.ts"
grep -Fq "sendEmailWithProvider" "$root/auth-send-email/index.ts"

echo 'Central email provider invariant: OK'
