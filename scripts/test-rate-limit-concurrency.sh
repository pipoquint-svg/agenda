#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
SCOPE="CONCURRENCY_LIMIT"
CLIENT_KEY="shared-client-key"
LIMIT="${LIMIT:-10}"
ATTEMPTS="${ATTEMPTS:-40}"
WINDOW_SECONDS=600
NOW_AT="2030-01-01 12:00:00+00"
KEY_HASH=$(printf '%s' "$CLIENT_KEY" | sha256sum | awk '{print $1}')
TMP_DIR="$(mktemp -d)"

cleanup() {
  psql "$DATABASE_URL" -qAtc "delete from public.public_rate_limit_buckets where scope='$SCOPE' and key_hash='$KEY_HASH';" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "delete from public.public_rate_limit_buckets where scope='$SCOPE' and key_hash='$KEY_HASH';"

for i in $(seq 1 "$ATTEMPTS"); do
  (
    if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "select public.service_consume_public_rate_limit_at('$SCOPE','$CLIENT_KEY',$LIMIT,$WINDOW_SECONDS,'$NOW_AT'::timestamptz);" >"$TMP_DIR/$i.out" 2>"$TMP_DIR/$i.err"; then
      echo success >"$TMP_DIR/$i.status"
    else
      if grep -q 'RATE_LIMITED' "$TMP_DIR/$i.err"; then
        echo limited >"$TMP_DIR/$i.status"
      else
        echo error >"$TMP_DIR/$i.status"
      fi
    fi
  ) &
done
wait

SUCCESS_COUNT=$(grep -l '^success$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
LIMITED_COUNT=$(grep -l '^limited$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
ERROR_COUNT=$(grep -l '^error$' "$TMP_DIR"/*.status 2>/dev/null | wc -l | tr -d ' ' || true)
PERSISTED_COUNT=$(psql "$DATABASE_URL" -qAtc "select request_count from public.public_rate_limit_buckets where scope='$SCOPE' and key_hash='$KEY_HASH';" | tr -d ' ')

printf 'Distributed rate limit concurrency: attempts=%s limit=%s success=%s limited=%s errors=%s persisted=%s\n' \
  "$ATTEMPTS" "$LIMIT" "$SUCCESS_COUNT" "$LIMITED_COUNT" "$ERROR_COUNT" "$PERSISTED_COUNT"

if [[ "$SUCCESS_COUNT" != "$LIMIT" ]]; then
  echo "FAIL: expected exactly $LIMIT aggregate successes across independent sessions."
  exit 1
fi
if [[ "$LIMITED_COUNT" != "$((ATTEMPTS - LIMIT))" ]]; then
  echo "FAIL: expected $((ATTEMPTS - LIMIT)) rate-limited attempts."
  exit 1
fi
if [[ "$ERROR_COUNT" != "0" ]]; then
  echo "FAIL: unexpected database errors occurred."
  for err in "$TMP_DIR"/*.err; do [[ -s "$err" ]] && { echo "--- $err"; cat "$err"; }; done
  exit 1
fi
if [[ "$PERSISTED_COUNT" != "$LIMIT" ]]; then
  echo "FAIL: persisted aggregate count is $PERSISTED_COUNT; expected $LIMIT."
  exit 1
fi

echo "PASS: separate PostgreSQL sessions shared one aggregate rate-limit bucket without race overflow."
