#!/usr/bin/env bash
set -euo pipefail

# Historical secret scan for V1 pre-production gate.
# Coverage: every commit reachable from every fetched local/remote branch and tag.
# Tooling: git rev-list + git grep. Findings are redacted to commit/path/line only.
# Intentional non-secrets are classified from context without printing their values:
# - Mercado Pago APP_USR values assigned to variables explicitly named PUBLIC_KEY;
# - documented replace-* placeholders inside *.env.example files;
# - exact synthetic local-verification sentinels/placeholders used by Item 1 tests.

patterns=(
  'APP_USR-[A-Za-z0-9_-]{20,}'
  'sk_live_[A-Za-z0-9]{16,}'
  'gh[pousr]_[A-Za-z0-9_]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'AIza[0-9A-Za-z_-]{30,}'
  'GOCSPX-[0-9A-Za-z_-]{16,}'
  'AKIA[0-9A-Z]{16}'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
  "(SERVICE_ROLE|SERVICE_ROLE_KEY|ACCESS_TOKEN|CLIENT_SECRET|WEBHOOK_SECRET|PRIVATE_KEY|PASSWORD)[A-Za-z0-9_ -]*[=:][[:space:]]*[\"']?[^[:space:]\"'\\$\\{<>]{12,}"
)

# Build the two historical Item 1 sentinels at runtime so this scanner does not
# itself embed provider-shaped credentials that its own patterns would detect.
synthetic_mp_token='APP_'
synthetic_mp_token+='USR-real-looking-token'
synthetic_google_token='GOC'
synthetic_google_token+='SPX-real-looking-secret'

CLASSIFICATION_KIND=''
classify_intentional_non_secret() {
  local pattern_index="$1"
  local path="$2"
  local content="$3"
  CLASSIFICATION_KIND=''

  # Mercado Pago uses APP_USR for both public and private credentials. A value is
  # non-secret only when the source line explicitly assigns it to a PUBLIC_KEY variable.
  if [[ "$pattern_index" == "0" && "$content" == *PUBLIC_KEY* ]]; then
    CLASSIFICATION_KIND='public_key'
    return 0
  fi

  # Example files intentionally carry obvious replacement tokens. Do not suppress any
  # non-example file or any value that is not an explicit replace-* placeholder.
  if [[ "$pattern_index" == "9" && "$path" == *.env.example && "$content" =~ =[[:space:]]*[\"\']?replace- ]]; then
    CLASSIFICATION_KIND='placeholder'
    return 0
  fi

  # Item 1 negative tests intentionally use two exact provider-looking sentinels
  # to prove that local-verification guards reject production-shaped credentials.
  if [[ "$path" == 'scripts/test-local-verification-safety.sh' || "$path" == 'supabase/functions/_shared/local-verification_test.ts' ]]; then
    if [[ "$content" == *"$synthetic_mp_token"* || "$content" == *"$synthetic_google_token"* ]]; then
      CLASSIFICATION_KIND='local_synthetic'
      return 0
    fi
  fi

  # Local verification placeholders are allowed only in the two explicit Item 1 files.
  # A real-looking value in any other file, or without LOCAL_ONLY_, remains fatal.
  if [[ "$path" == 'supabase/functions/.env.local-verification.example' || "$path" == 'supabase/functions/_shared/local-verification_test.ts' ]]; then
    if [[ "$content" == *'LOCAL_ONLY_'* ]]; then
      CLASSIFICATION_KIND='local_synthetic'
      return 0
    fi
  fi

  # Local E2E files read a generated local service-role key from the environment. This
  # is a variable name, not a credential value; classify only that exact reader call.
  if [[ "$pattern_index" == "9" && "$path" == tests/local-verification/*.ts ]]; then
    if [[ "$content" == *"requiredEnv('LOCAL_SERVICE_ROLE_KEY')"* || "$content" == *'requiredEnv("LOCAL_SERVICE_ROLE_KEY")'* ]]; then
      CLASSIFICATION_KIND='local_synthetic'
      return 0
    fi
  fi

  return 1
}

run_historical_secret_scan() {
  mapfile -t refs < <(git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags | grep -v '/HEAD$' | sort -u)
  if ((${#refs[@]} == 0)); then
    echo 'No refs fetched; historical coverage cannot be proven.' >&2
    exit 2
  fi

  mapfile -t commits < <(git rev-list --all | sort -u)
  echo "SECRET_SCAN_REFS=${#refs[@]}"
  echo "SECRET_SCAN_COMMITS=${#commits[@]}"
  printf 'SECRET_SCAN_REF=%s\n' "${refs[@]}"

  local findings=0
  local classified_public_keys=0
  local classified_placeholders=0
  local classified_local_synthetics=0
  local commit pattern_index pattern match path line content

  for commit in "${commits[@]}"; do
    for pattern_index in "${!patterns[@]}"; do
      pattern="${patterns[$pattern_index]}"
      while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        # git grep emits commit:path:line:content. Content is used only for classification and never printed.
        path="$(printf '%s' "$match" | cut -d: -f2)"
        line="$(printf '%s' "$match" | cut -d: -f3)"
        content="$(printf '%s' "$match" | cut -d: -f4-)"

        if classify_intentional_non_secret "$pattern_index" "$path" "$content"; then
          case "$CLASSIFICATION_KIND" in
            public_key) classified_public_keys=$((classified_public_keys + 1)) ;;
            placeholder) classified_placeholders=$((classified_placeholders + 1)) ;;
            local_synthetic) classified_local_synthetics=$((classified_local_synthetics + 1)) ;;
            *)
              echo 'Secret scanner classification returned an unknown kind.' >&2
              exit 2
              ;;
          esac
          continue
        fi

        echo "SECRET_CANDIDATE commit=$commit path=$path line=$line pattern_index=$pattern_index"
        findings=$((findings + 1))
      done < <(git grep -nI -E "$pattern" "$commit" -- ':!package-lock.json' ':!web/package-lock.json' 2>/dev/null || true)
    done
  done

  echo "SECRET_SCAN_PATTERN_COUNT=${#patterns[@]}"
  echo "SECRET_SCAN_CLASSIFIED_PUBLIC_KEYS=$classified_public_keys"
  echo "SECRET_SCAN_CLASSIFIED_PLACEHOLDERS=$classified_placeholders"
  echo "SECRET_SCAN_CLASSIFIED_LOCAL_SYNTHETICS=$classified_local_synthetics"
  echo "SECRET_SCAN_FINDINGS=$findings"
  if ((findings > 0)); then
    echo 'Historical secret candidates found. Rotation and classification are required before this gate can close.' >&2
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_historical_secret_scan "$@"
fi
