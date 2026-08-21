#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
RESOURCE_ID="00000000-0000-0000-0000-000000000101"
START_AT="2035-01-15 13:00:00+00"
END_AT="2035-01-15 14:00:00+00"
ATTEMPTS="${ATTEMPTS:-20}"

TMP_DIR="$(mktemp -d)"
cleanup() {
  psql "$DATABASE_URL" -qAtc "delete from public.resource_allocations where resource_id = '$RESOURCE_ID'::uuid and occupied_range = tstzrange('$START_AT'::timestamptz, '$END_AT'::timestamptz, '[)');" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "delete from public.resource_allocations where resource_id = '$RESOURCE_ID'::uuid and occupied_range = tstzrange('$START_AT'::timestamptz, '$END_AT'::timestamptz, '[)');"

for i in $(seq 1 "$ATTEMPTS"); do
  (
    if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "
      insert into public.resource_allocations (
        resource_id,
        allocation_type,
        status,
        occupied_range,
        reason
      ) values (
        '$RESOURCE_ID'::uuid,
        'MANUAL_BLOCK',
        'BLOCKED',
        tstzrange('$START_AT'::timestamptz, '$END_AT'::timestamptz, '[)'),
        'Gate A concurrency attempt $i'
      );
    " >"$TMP_DIR/$i.out" 2>"$TMP_DIR/$i.err"; then
      echo success >"$TMP_DIR/$i.status"
    else
      echo rejected >"$TMP_DIR/$i.status"
    fi
  ) &
done

wait

SUCCESS_COUNT=$(grep -l '^success$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
REJECTED_COUNT=$(grep -l '^rejected$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
DB_COUNT=$(psql "$DATABASE_URL" -qAtc "select count(*) from public.resource_allocations where resource_id = '$RESOURCE_ID'::uuid and status = 'BLOCKED' and occupied_range && tstzrange('$START_AT'::timestamptz, '$END_AT'::timestamptz, '[)');" | tr -d ' ')

printf 'Gate A concurrency result: attempts=%s success=%s rejected=%s persisted=%s\n' "$ATTEMPTS" "$SUCCESS_COUNT" "$REJECTED_COUNT" "$DB_COUNT"

if [[ "$SUCCESS_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one successful concurrent allocation."
  for err in "$TMP_DIR"/*.err; do
    if [[ -s "$err" ]]; then
      echo "--- $err"
      cat "$err"
    fi
  done
  exit 1
fi

if [[ "$DB_COUNT" != "1" ]]; then
  echo "FAIL: database contains $DB_COUNT overlapping blocking allocations; expected exactly 1."
  exit 1
fi

if [[ "$REJECTED_COUNT" != "$((ATTEMPTS - 1))" ]]; then
  echo "FAIL: expected $((ATTEMPTS - 1)) rejected attempts; got $REJECTED_COUNT."
  exit 1
fi

echo "PASS: PostgreSQL exclusion constraint made double booking impossible for this race."
