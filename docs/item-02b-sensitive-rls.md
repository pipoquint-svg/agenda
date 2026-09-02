# Item 2B — RLS deny-by-default nas 11 tabelas sensíveis

Data: 2026-09-02
Base: `main` em `0a9fed9f478514ef6dcab933a954a8790358929a`

## Escopo fechado

1. `customers`
2. `appointments`
3. `payment_transactions`
4. `payment_provider_events`
5. `checkout_holds`
6. `appointment_access_tokens`
7. `pre_reservation_access_tokens`
8. `google_connections`
9. `audit_logs`
10. `customer_balance_movements`
11. `google_calendar_events`

Nenhuma outra tabela, regra comercial, configuração Google, Mercado Pago, Kommo, `services` ou `service_change_policies` faz parte deste item.

## Estado read-only anterior

Em produção, antes da migration 2B:

- `customer_balance_movements`: RLS ON, FORCE OFF, zero policies;
- as outras 10 tabelas: RLS OFF, FORCE OFF, zero policies;
- `anon`: zero privilégio direto SELECT/INSERT/UPDATE/DELETE nas 11;
- `authenticated`: zero privilégio direto SELECT/INSERT/UPDATE/DELETE nas 11;
- `service_role`: `BYPASSRLS=true` e apenas os grants internos já existentes;
- `postgres`: owner e `BYPASSRLS=true`.

Logo, nenhuma policy de acesso direto é necessária para preservar um fluxo legítimo de browser.

## Matriz de acesso esperada após a 2B

| Papel/caminho | Acesso direto esperado | Mecanismo |
|---|---|---|
| `anon` | nenhum | sem ACL + RLS deny-by-default |
| `authenticated` | nenhum | sem ACL + RLS deny-by-default |
| `service_role` | somente grants internos já existentes | BYPASSRLS já existente; nenhuma policy nova |
| `postgres` | owner/interno | BYPASSRLS já existente; nenhuma policy nova |
| RPC/Edge Function pública legítima | apenas através do contrato estreito já existente | não recebe policy ampla de tabela |

A migration apenas executa `ENABLE ROW LEVEL SECURITY` nas 11 tabelas. Não altera ACL, não habilita FORCE RLS e não cria policy.

## Prova antes/depois

`141_sensitive_rls_deny_by_default.test.sql` possui 37 assertivas:

- 11 verificações de RLS ON;
- 11 verificações de FORCE RLS OFF;
- 11 verificações de zero policies;
- ausência agregada de CRUD direto para `anon`;
- ausência agregada de CRUD direto para `authenticated`;
- preservação de `service_role.rolbypassrls=true`;
- preservação de `postgres.rolbypassrls=true`.

Antes da migration, o gate exige exatamente 10 falhas nominais: todas as tabelas do conjunto, exceto `customer_balance_movements`. Qualquer falha adicional, ausente ou com nome diferente bloqueia o item. Depois da migration, as 37 precisam passar.

## Google Calendar

`google-sync` e `google-appointment-sync` usam `adminClient()`, criado com a chave `service_role`. Os caminhos auditados leem `google_connections`; também leem/escrevem o espelho `google_calendar_events` através de operações internas/RPCs.

O E2E local de Google foi fortalecido sem alterar o transporte mock:

1. cria `google_connections` e `google_calendars` via service-role local;
2. semeia um `google_calendar_events` externo local em estado `confirmed`;
3. executa `google-sync` em full-sync com o provedor mock vazio;
4. `prepare_google_full_sync` deve alterar o espelho externo para `status='cancelled'` e `qualification='CANCELLED'`;
5. o sync deve terminar `HEALTHY` e persistir o sync token;
6. a conexão deve continuar `ACTIVE`.

Isso prova um caminho real de leitura da conexão e escrita no espelho com RLS ativo, sem acesso à rede Google real e sem criar policy permissiva.

## Proibições

- nenhuma `USING (true)`;
- nenhuma policy genérica para destravar worker;
- nenhuma mudança de grant neste item;
- nenhuma alteração em OAuth, credenciais, calendário, mapping ou watch do Google;
- nenhuma alteração de Mercado Pago;
- nenhuma mudança comercial ou de disponibilidade.

## Gate de saída

Antes do merge:

1. failing-before exato das 10 tabelas;
2. rebuild completo por migrations;
3. 37/37 assertivas 2B verdes;
4. baseline global RLS sem diff;
5. contrato completo de testes de banco verde, mantendo somente as seis falhas estritamente autorizadas da futura 2C;
6. Database Core e demais workflows aplicáveis verdes;
7. E2E Google local comprova escrita em `google_calendar_events` com RLS ativo.

Somente então a migration pode ser aplicada em produção.

## Smoke de produção e rollback

Após o deploy, o smoke read-only deve provar:

- 55 tabelas `public` com RLS ativo;
- 0 FORCE RLS;
- as mesmas 3 policies globais anteriores;
- as 11 tabelas deste item com RLS ON e zero policies;
- `anon`/`authenticated` continuam sem CRUD direto nas 11.

Se o smoke falhar, o rollback deve ser versionado e limitar-se às 10 tabelas ativadas pela 2B: `customers`, `appointments`, `payment_transactions`, `payment_provider_events`, `checkout_holds`, `appointment_access_tokens`, `pre_reservation_access_tokens`, `google_connections`, `audit_logs` e `google_calendar_events`. `customer_balance_movements` não deve ser desabilitada porque seu RLS antecede a 2B.
