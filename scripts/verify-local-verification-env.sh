#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-supabase/functions/.env.local-verification.example}"
PROD_REF='sbexdggbwqvyhbkatucs'
LOCAL_PREFIX='LOCAL_ONLY_'
LOCAL_GOOGLE_KEY='bG9jYWwtdmVyaWZpY2F0aW9uLWtleS0zMi1ieXRlcyE='

if [[ ! -f "$ENV_FILE" ]]; then
  echo "LOCAL_VERIFICATION_ENV_FILE_NOT_FOUND:$ENV_FILE" >&2
  exit 1
fi

declare -A values=()

while IFS= read -r raw || [[ -n "$raw" ]]; do
  line="${raw%%$'\r'}"
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  if [[ "$line" != *=* ]]; then
    echo "LOCAL_VERIFICATION_ENV_LINE_INVALID" >&2
    exit 1
  fi
  key="${line%%=*}"
  value="${line#*=}"
  key="${key//[[:space:]]/}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  values["$key"]="$value"
done < "$ENV_FILE"

if [[ "${values[APP_ENV]:-}" != "local_verification" ]]; then
  echo "LOCAL_VERIFICATION_APP_ENV_REQUIRED" >&2
  exit 1
fi

if [[ -n "${values[MERCADO_PAGO_ENV]:-}" && "${values[MERCADO_PAGO_ENV]}" != "local_verification" ]]; then
  echo "LOCAL_VERIFICATION_MERCADO_PAGO_ENV_INVALID" >&2
  exit 1
fi

if [[ "${values[ALLOW_REAL_CHARGES]:-false}" == "true" ]]; then
  echo "LOCAL_VERIFICATION_REAL_CHARGES_FORBIDDEN" >&2
  exit 1
fi

for key in "${!values[@]}"; do
  value="${values[$key]}"
  [[ -z "$value" ]] && continue

  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" == *"$PROD_REF"* ]]; then
    echo "LOCAL_VERIFICATION_PRODUCTION_REFERENCE_FORBIDDEN:$key" >&2
    exit 1
  fi

  if [[ "$value" =~ ^https://[^/]*\.supabase\.co(/|$) ]]; then
    echo "LOCAL_VERIFICATION_HOSTED_SUPABASE_FORBIDDEN:$key" >&2
    exit 1
  fi

  if [[ "$value" == APP_USR-* || "$value" == GOCSPX-* || "$value" == ya29.* || "$value" =~ ^AIza[0-9A-Za-z_-]{20,}$ ]]; then
    echo "LOCAL_VERIFICATION_REAL_PROVIDER_CREDENTIAL_FORBIDDEN:$key" >&2
    exit 1
  fi

  if [[ "$key" =~ ^(VITE_)?MERCADO_PAGO_.*(TOKEN|SECRET|KEY)$ || "$key" =~ ^GOOGLE_.*(CLIENT_ID|CLIENT_SECRET|TOKEN|SECRET|KEY)$ ]]; then
    if [[ "$key" == "GOOGLE_TOKEN_ENCRYPTION_KEY" && "$value" == "$LOCAL_GOOGLE_KEY" ]]; then
      continue
    fi
    if [[ "$value" != "$LOCAL_PREFIX"* ]]; then
      echo "LOCAL_VERIFICATION_PROVIDER_CREDENTIAL_MUST_BE_PLACEHOLDER:$key" >&2
      exit 1
    fi
  fi
done

echo "local verification environment: safe"
