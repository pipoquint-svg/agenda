# Item 3 — Matriz canônica de autenticação das Edge Functions

## Objetivo

Fechar o contrato de autenticação e implantação das Edge Functions da Agenda sem alterar regras de negócio, credenciais ou integrações externas.

A auditoria original registrou corretamente que `verify_jwt=false` não significa endpoint público: a Agenda usa boundaries próprios para Supabase Auth administrativo, links/tokens opacos, segredos internos, webhooks assinados, Google channel tokens e GitHub OIDC.

## Baseline de produção — 2026-09-02

- 63 Edge Functions `ACTIVE`;
- 48 com `verify_jwt=false`;
- 15 com `verify_jwt=true`;
- 58 slugs ativos também existem no `main`;
- 11 slugs existem no `main`, mas não estão ativos neste projeto de produção;
- 5 slugs estão ativos em produção, já não existem no `main` e retornam tombstone 410.

Os cinco deployed-orphans ficam **preserve-only** neste item:

- `owner-magiclink-bootstrap-temp`;
- `admin-finance-auth-smoke-temp`;
- `admin-contracts-auth-smoke-temp`;
- `mercado-pago-readiness-probe-temp`;
- `guard-kommo-secret-migrate-20260901`.

Sua remoção pertence à etapa posterior de higiene; o Item 3 não os redeploya nem os exclui.

## Contrato versionado

`supabase/functions/auth-contract.json` registra as 69 funções versionadas, agrupadas por boundary, em duas superfícies: `deployable` e `inactive`.

O script `scripts/edge-auth-contract.py` exige que:

1. todo diretório local tenha uma entrada no manifest e vice-versa;
2. os 58 slugs ativos/versionados sejam a única allowlist oficial de deploy;
3. os 11 slugs locais inativos permaneçam fora do deploy oficial;
4. `supabase/config.toml` reproduza o `verify_jwt` efetivo do manifest;
5. toda função `verify_jwt=false` tenha no código o marcador correspondente ao boundary declarado;
6. o workflow de produção não possua `supabase functions deploy` irrestrito.

## Failing-before

O modo `before` recria exatamente o estado anterior a esta correção e exige os seguintes problemas conhecidos:

- seis funções ativas `verify_jwt=false` sem override correspondente no `config.toml`;
- `admin-special-calendar` com `true` em produção e `false` no config;
- deploy de Edge Functions irrestrito;
- ausência da allowlist;
- os 11 slugs locais inativos passíveis de ativação acidental pelo deploy irrestrito.

Qualquer falha diferente ou adicional faz o gate falhar.

## Passing-after

O modo `after` deve produzir somente:

`ITEM03_AUTH_CONTRACT_OK`

O comando `list-deployable` também valida o contrato inteiro antes de imprimir os 58 slugs permitidos.

## Produção

Este item não exige mutação imediata em produção porque o `config.toml` foi alinhado para **preservar os estados já observados em produção**. A mudança operacional é fail-closed: futuros deploys oficiais passam a implantar apenas a allowlist versionada.

Não foram alterados:

- OAuth, credenciais, calendários ou watches do Google;
- tokens, webhook ou conta do Mercado Pago;
- Kommo;
- secrets;
- banco, migrations ou regras comerciais.

## Smoke pós-merge

Somente leitura:

1. relistar as Edge Functions de `sbexdggbwqvyhbkatucs`;
2. confirmar 63 `ACTIVE`, 48 `verify_jwt=false`, 15 `true`;
3. confirmar que os 58 slugs versionados ativos mantêm o mesmo estado de gateway;
4. confirmar que os 11 slugs locais inativos continuam ausentes;
5. confirmar que os cinco deployed-orphans continuam tombstonados/preserve-only.

Nenhum replay mutável de provider é necessário ou permitido para fechar este item.
