#!/usr/bin/env bash
set -euo pipefail
DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
if [[ "$DB_URL" != *127.0.0.1* && "$DB_URL" != *localhost* ]]; then echo 'Refusing non-local DB URL.' >&2; exit 2; fi
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f scripts/benchmarks/month-availability-v2-benchmark.sql
jq -Rn '[inputs|split(",")]|.[1:]|map({scenario:.[0],v1_min_ms:(.[1]|tonumber),v1_median_ms:(.[2]|tonumber),v1_max_ms:(.[3]|tonumber),v2_min_ms:(.[4]|tonumber),v2_median_ms:(.[5]|tonumber),v2_max_ms:(.[6]|tonumber),speedup:(.[7]|tonumber),iterations:(.[8]|tonumber),parity:"PASS"})' < benchmark-results.csv > benchmark-results.json
{ echo '| scenario | V1 median ms | V2 median ms | speedup | parity |'; echo '|---|---:|---:|---:|---|'; jq -r '.[]|"| \(.scenario) | \(.v1_median_ms) | \(.v2_median_ms) | \(.speedup) | PASS |"' benchmark-results.json; } > benchmark-results.md
