#!/usr/bin/env bash
set -euo pipefail

# Historical secret scan for V1 pre-production gate.
# Coverage: every commit reachable from every fetched local/remote branch and tag.
# Tooling: git rev-list + git grep. Findings are redacted to commit/path/line only.

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

mapfile -t refs < <(git for-each-ref --format='%(refname)' refs/heads refs/remotes refs/tags | grep -v '/HEAD$' | sort -u)
if ((${#refs[@]} == 0)); then
  echo 'No refs fetched; historical coverage cannot be proven.' >&2
  exit 2
fi

mapfile -t commits < <(git rev-list --all | sort -u)
echo "SECRET_SCAN_REFS=${#refs[@]}"
echo "SECRET_SCAN_COMMITS=${#commits[@]}"
printf 'SECRET_SCAN_REF=%s\n' "${refs[@]}"

findings=0
for commit in "${commits[@]}"; do
  for pattern_index in "${!patterns[@]}"; do
    pattern="${patterns[$pattern_index]}"
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      # git grep emits commit:path:line:content. Never print the content.
      path="$(printf '%s' "$match" | cut -d: -f2)"
      line="$(printf '%s' "$match" | cut -d: -f3)"
      echo "SECRET_CANDIDATE commit=$commit path=$path line=$line pattern_index=$pattern_index"
      findings=$((findings + 1))
    done < <(git grep -nI -E "$pattern" "$commit" -- ':!package-lock.json' ':!web/package-lock.json' 2>/dev/null || true)
  done
done

echo "SECRET_SCAN_PATTERN_COUNT=${#patterns[@]}"
echo "SECRET_SCAN_FINDINGS=$findings"
if ((findings > 0)); then
  echo 'Historical secret candidates found. Rotation and classification are required before this gate can close.' >&2
  exit 1
fi
