# Kommo Guard — snapshot sanitizado do sandbox (2026-08-25)

Este artefato preserva a evidência necessária para eventual remoção segura do cluster remoto `kommo_guard_*` do sandbox da Agenda. Ele **não é migration autoritativa**, não deve ser aplicado automaticamente e não habilita Kommo LIVE.

## Origem e estado

- Supabase sandbox: `jlyvlvmspfjwbcmhmhwz`.
- 10 tabelas remotas `public.kommo_guard_*` + função `public.kommo_guard_adjust_due(timestamptz)`.
- Nenhuma migration de criação correspondente existe na `main` da Agenda.
- Tabelas operacionais estavam vazias na auditoria anterior; somente settings, 18 regras e discovery cache continham estado residual.
- A integração Kommo autoritativa da Agenda permanece separada e `kommo_integration_settings.enabled=false`.
- Este snapshot não contém token, segredo, hash de segredo, mensagem, contato, lead ou payload de cliente.

## Settings sanitizados

| campo | valor |
|---|---|
| id | 1 |
| enabled | true |
| mode | `SHADOW` |
| dispatch_enabled | false |
| reconcile_enabled | true |
| tick_enabled | true |
| account_subdomain | `pierriquintproducoes` |
| pipeline_id | `9039711` |
| urgent_stage_id | `95794124` |
| lost_stage_id | `143` |
| timezone | `America/Sao_Paulo` |
| business_open | `13:00:00` |
| business_close | `19:00:00` |
| business_days | `{1,2,3,4,5}` |
| cron_secret_hash | **REDACTED**; somente `configured=true` foi preservado |
| created_at / updated_at | `2026-08-24 17:28:38.024618+00` |

## 18 regras seedadas

| code | journey | service_tag | priority_tag | source_stage | seq | delay_s | bot_id |
|---|---|---:|---:|---:|---:|---:|---:|
| GESTANTE_FU1 | GESTANTE | 125035 | — | 70440571 | 1 | 86400 | 64374 |
| GESTANTE_FU2_ALTA | GESTANTE | 125035 | 124899 | 70440567 | 2 | 259200 | 64420 |
| GESTANTE_FU2_BAIXA | GESTANTE | 125035 | 124895 | 70440567 | 2 | 432000 | 64420 |
| GESTANTE_FU2_MEDIA | GESTANTE | 125035 | 124897 | 70440567 | 2 | 604800 | 64420 |
| GESTANTE_FU3_AQUECER_ALTA | GESTANTE | 125035 | 124899 | 70440563 | 3 | 432000 | 64428 |
| GESTANTE_FU3_AQUECER_BAIXA | GESTANTE | 125035 | 124895 | 70440563 | 3 | 604800 | 64424 |
| GESTANTE_FU3_AQUECER_MEDIA | GESTANTE | 125035 | 124897 | 70440563 | 3 | 1209600 | 64426 |
| GESTANTE_FU3_QUENTE_ALTA | GESTANTE | 125035 | 124899 | 106972415 | 3 | 432000 | 64422 |
| GESTANTE_FU3_QUENTE_BAIXA | GESTANTE | 125035 | 124895 | 106972415 | 3 | 604800 | 64422 |
| GESTANTE_FU3_QUENTE_MEDIA | GESTANTE | 125035 | 124897 | 106972415 | 3 | 1209600 | 64422 |
| GESTANTE_FINAL_ALTA | GESTANTE | 125035 | 124899 | 109088111 | 4 | 604800 | 64430 |
| GESTANTE_FINAL_BAIXA | GESTANTE | 125035 | 124895 | 109088111 | 4 | 691200 | 64430 |
| GESTANTE_FINAL_MEDIA | GESTANTE | 125035 | 124897 | 109088111 | 4 | 1814400 | 64430 |
| PARTO_FU1 | PARTO | 125059 | — | 70440571 | 1 | 86400 | 64376 |
| PARTO_FU2_ALTA | PARTO | 125059 | 124899 | 70440567 | 2 | 345600 | 63495 |
| PARTO_FU2_MEDIA | PARTO | 125059 | 124897 | 70440567 | 2 | 864000 | 63487 |
| PARTO_FU3_ALTA | PARTO | 125059 | 124899 | 106972415 | 3 | 518400 | 63497 |
| PARTO_FU3_MEDIA | PARTO | 125059 | 124897 | 106972415 | 3 | 864000 | 63489 |

Todas estavam `active=true` e foram criadas/atualizadas em `2026-08-24 17:28:38.024618+00`.

## DDL reconstruível preservado

### Tabelas e chaves

- `kommo_guard_settings(id smallint PK, enabled, mode, dispatch_enabled, reconcile_enabled, tick_enabled, account_subdomain, pipeline_id, urgent_stage_id, lost_stage_id, timezone, business_open, business_close, business_days smallint[], cron_secret_hash, created_at, updated_at)`; checks `id=1`, `mode in ('SHADOW','GUARD','LIVE')`.
- `kommo_guard_rules(id uuid PK default gen_random_uuid(), code text UNIQUE, journey_type, service_tag_id, priority_tag_id, source_stage_id, sequence_no, delay_seconds, bot_id, active, notes, created_at, updated_at)`; checks journey `GESTANTE/PARTO/ABANDONO`, `sequence_no>0`, `delay_seconds>=0`.
- `kommo_guard_schedules(id uuid PK, lead_id, rule_id FK -> kommo_guard_rules ON DELETE RESTRICT, journey_type, service_tag_id, priority_tag_id, pipeline_id, stage_id, stage_entered_at, anchor_at, anchor_source, raw_due_at, due_at, source, status, conflict_reason, attempts, run_requested_at, confirmation_deadline_at, confirmed_at, deferred_until, cancelled_at, cancellation_reason, last_checked_at, last_error_code, last_error, matched_outgoing_message_id, snapshot, created_at, updated_at)`; UNIQUE `(lead_id, rule_id, stage_entered_at)`; `attempts>=0`; source enum `WEBHOOK/RECONCILIATION/BACKFILL/MANUAL`; status enum `PENDING/DUE/OVERDUE/RUN_REQUESTED/WAITING_CONFIRMATION/CONFIRMED/DEFERRED/RETRY/CANCELLED/FAILED/RULE_CONFLICT`.
- `kommo_guard_audit_log(id bigint PK, schedule_id FK -> schedules ON DELETE SET NULL, lead_id, event_type, old_status, new_status, details jsonb, created_at)`.
- `kommo_guard_outgoing_messages(message_id text PK, talk_id, chat_id, contact_id, lead_id, text_body, author_type, delivery_status, sent_at, webhook_payload, matched_schedule_id FK -> schedules ON DELETE SET NULL, match_method, match_score, verified_at, created_at)`.
- `kommo_guard_lead_state(lead_id bigint PK, pipeline_id, stage_id, service_tag_id, priority_tag_id, tags, stage_entered_at, stage_entry_source, last_outgoing_at, last_incoming_at, conflict_code, lead_name, last_seen_at, raw_snapshot, created_at, updated_at)`.
- `kommo_guard_reconciliation_runs(id uuid PK, run_kind, started_at, finished_at, leads_scanned, monitored_leads, schedules_created, schedules_updated, schedules_cancelled, conflicts, errors, details)`.
- `kommo_guard_talks(talk_id text PK, chat_id, contact_id, lead_id, entity_type, is_in_work, kommo_created_at, kommo_updated_at, last_synced_at)`.
- `kommo_guard_webhook_inbox(id uuid PK, webhook_type, dedupe_key text UNIQUE, payload jsonb, received_at, processed_at, processing_error)`.
- `kommo_guard_discovery_cache(id smallint PK CHECK id=1, pipeline jsonb, statuses jsonb, salesbots jsonb, tags jsonb, discovered_at, meta jsonb, pipelines jsonb, bot_details jsonb)`.

### Índices adicionais não cobertos por PK/UNIQUE

```sql
CREATE INDEX kommo_guard_audit_lead_idx ON public.kommo_guard_audit_log (lead_id, created_at DESC);
CREATE INDEX kommo_guard_audit_schedule_idx ON public.kommo_guard_audit_log (schedule_id, created_at DESC);
CREATE INDEX kommo_guard_rules_lookup_idx ON public.kommo_guard_rules (source_stage_id, service_tag_id, priority_tag_id) WHERE active = true;
CREATE INDEX kommo_guard_schedules_due_idx ON public.kommo_guard_schedules (due_at) WHERE status = ANY (ARRAY['PENDING','DUE','OVERDUE','RETRY','DEFERRED']);
CREATE INDEX kommo_guard_schedules_lead_idx ON public.kommo_guard_schedules (lead_id, created_at DESC);
```

### Função remota

`kommo_guard_adjust_due(timestamptz)` é `LANGUAGE plpgsql STABLE`, `search_path=public`; lê apenas `kommo_guard_settings` e move timestamps para o próximo horário/dia útil conforme `timezone`, `business_open`, `business_close` e `business_days`. Não chama provider.

## Estado de dados preservado para decisão de cleanup

O snapshot intencionalmente não reproduz discovery cache nem qualquer payload remoto. A evidência necessária para reconstruir a configuração funcional foi preservada sem secrets. Antes de qualquer DROP, ainda é obrigatório provar que nenhum repositório/projeto externo usa fisicamente este banco e executar cleanup com assertions, sem `CASCADE` cego.
