# Item 2A-bis — baseline completa de RLS do `public`

Data: 2026-09-02

## Decisão

A Fase 2B somente pode começar depois de uma reconstrução limpa do banco, exclusivamente pelas migrations, reproduzir integralmente o estado de RLS observado em produção. O gate de rebuild deixa de ser recomendação e passa a ser condição de abertura/deploy.

A Fase 2B tem 11 tabelas:

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

`google_calendar_events` é sensível pelo mesmo motivo de `google_connections`: guarda o vínculo operacional entre reserva e evento Google. Antes de qualquer deploy da 2B, os workers Google devem provar localmente a leitura e a escrita necessárias. Se o RLS interferir na sincronização, o deploy deve parar e o problema deve ser reportado. É proibido criar policy permissiva improvisada para destravar o worker.

## Baseline de produção da 2A-bis

Inventário read-only do schema `public` inteiro, não apenas das 11 tabelas:

- 105 tabelas;
- 45 tabelas com `relrowsecurity=true`;
- 0 tabelas com `relforcerowsecurity=true`;
- 3 policies existentes;
- inventário canônico inclui, para cada tabela, `relrowsecurity` e `relforcerowsecurity`;
- inventário canônico inclui, para cada policy, tabela, nome, permissividade, roles, comando, `USING`/`qual` e `WITH CHECK`.

O rebuild de `main` por `supabase db reset` produziu diff vazio contra esse baseline. Portanto não existe, no estado atual, DDL de reconciliação RLS a versionar. Não foi criada migration vazia ou corretiva artificial.

`customer_balance_movements` deve permanecer exatamente como observado e reproduzido: RLS ligado, FORCE RLS desligado e zero policies.

## Origem do drift RLS

A auditoria de 1–2/09/2026 registrou `customer_balance_movements` existente com RLS desligado. O arquivo `supabase/migrations/20260822163000_customer_balance_and_change_settlement.sql` já estava versionado no Git desde 22/08/2026 e, no mesmo arquivo que cria a tabela, executa explicitamente:

```sql
alter table public.customer_balance_movements enable row level security;
```

Não existe migration posterior à coleta da auditoria que reabilite RLS nessa tabela. O histórico de migrations posterior à coleta contém habilitações para tabelas novas, mas não uma reconciliação de `customer_balance_movements`. Os logs Postgres disponíveis têm janela curta e não alcançam o instante histórico da alteração; eles apenas confirmam que o projeto possui mecanismo `rls_auto_enable` para criação de tabelas novas.

Pela regra de classificação desta fase, a divergência observada entre o código versionado e a fotografia de produção não tem migration correspondente posterior que a explique. Ela é registrada como alteração fora do fluxo versionado — segunda ocorrência do mesmo problema de processo já observado em ACL, agora em RLS.

Situação atual: o drift foi eliminado no estado corrente, pois produção e rebuild por migrations são idênticos para o inventário RLS completo.

## Gate obrigatório

`.github/workflows/item-02a-bis-rls-baseline.yml` executa em todo pull request para `main` e em todo push para `main`:

1. inicia Supabase local descartável;
2. executa `supabase db reset`;
3. extrai o inventário completo por `scripts/rls-inventory.sql`;
4. compara linha a linha com `tests/rls-parity/production_rls_baseline.txt`;
5. falha se houver qualquer diferença;
6. publica o diff como evidência do run.

A integração usada nesta auditoria não possui permissão para ler/configurar a proteção nativa de branch do GitHub (HTTP 403). Portanto este documento não afirma que o status check já esteja marcado como `required` em Branch Protection. Independentemente dessa limitação, a regra operacional é vinculante: abertura/deploy não é autorizado com esse gate ausente ou vermelho.

Mudanças RLS intencionais futuras devem alterar migration + baseline esperado de forma explícita, passar por rebuild limpo e, após o deploy, repetir o inventário read-only de produção para provar paridade. Alterar o baseline isoladamente para mascarar um diff é proibido.

## Regras da Fase 2B

- deny-by-default nas 11 tabelas;
- criar policy somente quando houver necessidade real comprovada;
- `USING (true)` é proibido;
- produzir matriz de acesso antes e depois;
- provar os caminhos de Edge Functions/RPCs/workers localmente antes do deploy;
- para `google_connections` e `google_calendar_events`, qualquer regressão de sincronização causada por RLS é condição de parada, não convite para policy ampla.
