#!/usr/bin/env bash
set -euo pipefail

: "${LOCAL_DATABASE_URL:?LOCAL_DATABASE_URL required}"
: "${SANDBOX_DATABASE_URL:?SANDBOX_DATABASE_URL required}"

out_dir="${AUDIT_OUT_DIR:-artifacts/preprod-audit}"
mkdir -p "$out_dir"
report="$out_dir/report.md"

{
  echo '# Auditoria consolidada V1 pré-produção'
  echo
  echo "Commit: \`${GITHUB_SHA:-local}\`"
  echo
} > "$report"

# 1) Working-tree debt/test markers. This intentionally scans the checked-out
# repository rather than GitHub code search so coverage is complete.
marker_file="$out_dir/tree-markers.txt"
: > "$marker_file"
while IFS= read -r -d '' file; do
  grep -nEi '\b(TODO|FIXME|XXX|HACK)\b|pend[eê]ncia|\.skip\s*\(|\.todo\s*\(|\bxit\s*\(|\bxdescribe\s*\(|@skip|SKIP[[:space:]]*:' "$file" \
    | sed "s#^#$file:#" >> "$marker_file" || true
done < <(find . -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './web/node_modules/*' -not -path './artifacts/*' -print0)

{
  echo '## 1. Marcadores de dívida e testes pulados'
  echo
  echo "Cobertura: todos os arquivos da árvore, excluindo apenas .git, node_modules e artefatos gerados."
  echo
  echo "Ocorrências: **$(wc -l < "$marker_file" | tr -d ' ')**"
  if [[ -s "$marker_file" ]]; then
    echo
    echo '```text'
    sed -n '1,200p' "$marker_file"
    if (( $(wc -l < "$marker_file") > 200 )); then echo '... resultado completo no artifact ...'; fi
    echo '```'
  fi
  echo
} >> "$report"

# 2) Full Edge Function static inventory. Type-checking is a separate CI gate;
# here we prove every entrypoint was visited and expose error/status patterns for
# review instead of silently assuming one framework shape.
edge_file="$out_dir/edge-functions.tsv"
printf 'function\tcatch_or_rejection\texplicit_status\tthrow_or_error\n' > "$edge_file"
edge_count=0
while IFS= read -r -d '' file; do
  edge_count=$((edge_count + 1))
  fn="$(basename "$(dirname "$file")")"
  catch=no; status=no; err=no
  grep -Eq '\bcatch\b|\.catch\s*\(' "$file" && catch=yes || true
  grep -Eq 'status[[:space:]]*:|new Response\(|Response\.json\(' "$file" && status=yes || true
  grep -Eq '\bthrow\b|console\.error|errorResponse|jsonError|respondError' "$file" && err=yes || true
  printf '%s\t%s\t%s\t%s\n' "$fn" "$catch" "$status" "$err" >> "$edge_file"
done < <(find supabase/functions -mindepth 2 -maxdepth 2 -type f -name index.ts -print0 | sort -z)

{
  echo '## 2. Edge Functions — tratamento de erro/status'
  echo
  echo "Cobertura: **$edge_count entrypoints** `supabase/functions/*/index.ts`, sem amostragem."
  echo
  echo '| Function | catch/rejection | resposta/status explícito | throw/error path |'
  echo '|---|---:|---:|---:|'
  tail -n +2 "$edge_file" | while IFS=$'\t' read -r fn catch status err; do
    echo "| \`$fn\` | $catch | $status | $err |"
  done
  echo
  echo '> `no` não é automaticamente defeito: funções podem delegar erro/status a helpers importados. O inventário serve para revisão integral e evita falso negativo por índice de busca.'
  echo
} >> "$report"

# 3) Structural schema comparison: declared/migrated local database vs sandbox.
# Compare semantic catalog objects, not migration history.
query_columns="copy (select n.nspname, c.relname, a.attnum, a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull, coalesce(pg_get_expr(d.adbin,d.adrelid),''), a.attidentity, a.attgenerated from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum where n.nspname='public' and c.relkind in ('r','p','v','m') and a.attnum>0 and not a.attisdropped order by 1,2,3) to stdout with csv"
query_constraints="copy (select c.relname, con.conname, con.contype, con.condeferrable, con.condeferred, con.convalidated, pg_get_constraintdef(con.oid,true) from pg_constraint con join pg_class c on c.oid=con.conrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' order by 1,2) to stdout with csv"
query_indexes="copy (select tablename,indexname,indexdef from pg_indexes where schemaname='public' order by 1,2) to stdout with csv"
query_functions="copy (select p.proname, pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid), l.lanname, p.provolatile, p.prosecdef, regexp_replace(pg_get_functiondef(p.oid),'[[:space:]]+',' ','g') from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang where n.nspname='public' order by 1,2) to stdout with csv"

schema_failed=0
for object in columns constraints indexes functions; do
  qvar="query_${object}"
  q="${!qvar}"
  PGPASSWORD='' psql "$LOCAL_DATABASE_URL" -X -qAtc "$q" > "$out_dir/local-${object}.csv"
  PGPASSWORD='' psql "$SANDBOX_DATABASE_URL" -X -qAtc "$q" > "$out_dir/sandbox-${object}.csv"
  if ! diff -u "$out_dir/local-${object}.csv" "$out_dir/sandbox-${object}.csv" > "$out_dir/${object}.diff"; then
    schema_failed=1
  fi
done

{
  echo '## 3. Diff estrutural schema declarado × sandbox'
  echo
  echo 'Cobertura: tabelas/views + colunas, constraints, índices e funções do schema `public`. Histórico de migrations não é usado como substituto.'
  echo
  for object in columns constraints indexes functions; do
    if [[ -s "$out_dir/${object}.diff" ]]; then
      echo "- **$object:** DIFERENÇA ENCONTRADA (ver artifact)"
    else
      echo "- **$object:** idêntico"
    fi
  done
  echo
} >> "$report"

cat "$report"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$report" >> "$GITHUB_STEP_SUMMARY"
fi

if (( schema_failed != 0 )); then
  echo 'Structural schema drift detected between migrated repository state and sandbox.' >&2
  exit 1
fi
