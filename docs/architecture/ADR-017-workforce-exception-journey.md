# ADR-017 — Jornada por Exceção na Agenda

## Status
Aprovado em 2026-10-08.

## Contexto
A BlackSheep precisa controlar a jornada da funcionária por exceção, fechar a competência mensal e enviar o relatório à contadora. A Agenda já tem autenticação, papéis, o tenant `blacksheep`, Resend e schedules com token OIDC. O frontend BlackSheep usa o mesmo projeto Supabase da Agenda, mas não versiona migrations.

## Decisão
1. O domínio vive na Agenda. Backend em `pipoquint-svg/agenda` e interface em `pipoquint-svg/black-sheep`. Não há dependência do Dracma nem banco paralelo.
2. As tabelas ficam no schema `workforce`, que não é exposto pelo PostgREST. `anon` e `authenticated` não têm privilégios nele, e as tabelas usam RLS habilitada e forçada, sem policies.
3. Toda mutação e leitura passa por RPCs `public.service_workforce_*` (`SECURITY DEFINER`, `search_path` vazio, `EXECUTE` só para `service_role`), chamadas pelas Edge Functions `workforce-employee` e `admin-workforce`. Ator, tenant, empregadora e funcionário são derivados no servidor.
4. As ações administrativas exigem role `OWNER` com membership OWNER ativa no tenant. ADMIN, OPERATION e FINANCE não herdam acesso no V1.
5. As slices são mergeadas em `workforce-v1`, em cada repositório. `main` e produção ficam intocados até a conclusão de S0–S8 e a autorização explícita.
6. A apuração, os alertas e o fechamento rodam no banco (plpgsql determinístico) e são cobertos por pgTAP. A interface só exibe resultados.

## Consequências
- Cada slice com RPC pública atualiza as contagens de `tests/acl-parity/item02c_acl_overlay.sql` com justificativa.
- Cada Edge Function nova entra em `supabase/functions/auth-contract.json`.
- Os gates centrais rodam também para PRs em `workforce-v1`.
- O schedule de envio (S8) só vale após o merge em `main` e fica separado da migration.

Especificação completa: [WORKFORCE-EXCEPTION-JOURNEY-V1.md](WORKFORCE-EXCEPTION-JOURNEY-V1.md).
