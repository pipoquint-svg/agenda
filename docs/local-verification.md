# Item 1 — Ambiente local de verificação das locações

Este ambiente existe para validar o caminho crítico de locações sem copiar o banco de
produção e sem conectar Google, Mercado Pago, Resend ou qualquer outro provedor externo.

## Garantias de segurança

- O banco nasce exclusivamente das migrations com `supabase db reset`.
- A massa de locação é `supabase/fixtures/locacao-local-verification.sql` e usa somente
  IDs reservados para QA e e-mails `example.test`.
- `APP_ENV=local_verification` instala um transporte fail-closed nas Edge Functions.
- Google e Mercado Pago são simulados em processo. Não existe túnel, webhook exposto,
  credencial real nem chamada ao domínio real dos provedores.
- Qualquer host HTTP(S) não local é bloqueado durante `local_verification`.
- O preflight e o runtime rejeitam a referência de produção
  `sbexdggbwqvyhbkatucs`, qualquer URL hospedada `*.supabase.co`, credenciais com
  aparência real e qualquer valor de credencial de Google/MP que não seja placeholder
  `LOCAL_ONLY_`.
- `ALLOW_REAL_CHARGES=true` é proibido.
- O painel `/admin` e `/gestao` mostra `AMBIENTE LOCAL_VERIFICATION — DADOS DE TESTE`.

## Pré-requisitos

- Docker
- Supabase CLI 2.111.0
- PostgreSQL client (`psql`)
- Deno 2
- Node 22 para o smoke do frontend

## Subir

```bash
supabase start
supabase db reset

psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  -v ON_ERROR_STOP=1 \
  -f supabase/fixtures/locacao-local-verification.sql

bash scripts/verify-local-verification-env.sh \
  supabase/functions/.env.local-verification.example

supabase functions serve \
  --env-file supabase/functions/.env.local-verification.example
```

Em outro terminal, exporte apenas as chaves **locais** emitidas pelo CLI:

```bash
eval "$(supabase status -o env)"
export LOCAL_API_URL="$API_URL"
export LOCAL_ANON_KEY="$ANON_KEY"
export LOCAL_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY"

deno test --allow-env --allow-net=127.0.0.1:54321,localhost:54321 \
  tests/local-verification/item01_e2e_test.ts
```

## Resetar

```bash
supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  -v ON_ERROR_STOP=1 \
  -f supabase/fixtures/locacao-local-verification.sql
```

O reset apaga todos os clientes, reservas, holds, transações e usuários administrativos
criados pelos testes locais.

## Derrubar

```bash
supabase stop --no-backup
```

## Provas automatizadas

`supabase/functions/_shared/local-verification_test.ts` comprova:

- rejeição da referência/URL de produção;
- rejeição de credenciais de Google e Mercado Pago;
- contrato de Order Pix aprovado;
- respostas simuladas de rejeição e erro 5xx;
- contrato de token/evento Google;
- bloqueio de host externo;
- assinatura HMAC do webhook do Mercado Pago com segredo fictício.

`tests/local-verification/item01_e2e_test.ts` percorre:

1. criação de hold pela Edge Function real;
2. bind de cliente fictício;
3. promoção do checkout para reserva;
4. leitura do saldo inicial;
5. cancelamento administrativo de outra locação;
6. Pix marcado como pendência da Fase 2A e obrigado a falhar exatamente no drift de ACL;
7. no-show como defeito conhecido do Item 7.

## Achado novo — ACL drift

**Severidade: ALTA.**

O Item 1 revelou que o estado de privilégios efetivos do banco de produção não é
reproduzido integralmente pelas migrations do repositório. No banco local reconstruído
do zero, uma requisição PostgREST autenticada com a chave local de `service_role`
recebe `403 / SQLSTATE 42501` ao ler `public.payment_transactions`, com
`permission denied for table payment_transactions`.

Ao mesmo tempo, o fluxo de pagamento em produção funciona e a inspeção somente leitura
do ambiente hospedado mostra privilégios efetivos que não estão sendo reconstruídos no
local. Isso significa que, neste momento, **o banco não é reconstruível a partir do
repositório com equivalência de ACL**, mesmo que schema, funções e testes SQL sejam
recriados com sucesso.

Esse achado não é classificado como “falha conhecida” do Item 1. Ele é uma descoberta
nova desta rodada e deve entrar como achado próprio no relatório final.

O Item 1 deliberadamente **não** adiciona `GRANT`, `REVOKE`, RLS ou qualquer outra
correção de ACL para não antecipar o Item 2.

### Fase 2A — baseline de ACL

Antes de qualquer alteração de RLS, a Fase 2A deve:

1. levantar em produção, somente leitura, o mapa completo de privilégios de todas as
   tabelas, views, funções e sequences do schema `public`, por role, incluindo `anon`,
   `authenticated`, `service_role` e roles internas relevantes;
2. reconstruir o banco local exclusivamente pelas migrations;
3. levantar o mesmo mapa no local;
4. produzir o diff completo produção × local;
5. versionar em migration os grants/revokes faltantes para que o local reproduza
   produção exatamente;
6. repetir o diff até ficar vazio;
7. somente então remover o `TODO(Phase 2A)` do teste de Pix e exigir o fluxo Pix verde,
   sem nenhuma mudança de RLS.

A conclusão anterior da auditoria de que produção não possui grants diretos para
`anon`/`authenticated` continua válida para produção, mas a Fase 2A deve confirmar
explicitamente os dois lados do diff. O Item 3 permanece bloqueado até a Fase 2A estar
verde, pois uma matriz de autorização executada com ACL divergente não é evidência
válida.

### Pix — pendência explícita da Fase 2A

O teste ativo exige que o primeiro Pix falhe exatamente no boundary de ACL/PostgREST e
confirma em seguida o `403 / 42501` de `payment_transactions` para `service_role` no
local reconstruído.

Logo abaixo existe um teste `ignore: true` com `TODO(Phase 2A)` para o comportamento
alvo: Pix de sinal, saldo remanescente, Pix de quitação e confirmação da reserva.

A Fase 2A não está concluída enquanto esse `ignore: true` existir.

### No-show — falha conhecida esperada

O teste ativo exige que `NO_SHOW` falhe **exatamente** porque o RPC
`public.service_admin_mark_appointment_no_show_evidenced` não existe. Logo abaixo há um
teste `ignore: true` com `TODO(Item 7)` para o comportamento final.

No Item 7, a marcação `ignore: true` deve ser removida e o teste precisa ficar verde.
O Item 7 não está concluído enquanto essa marcação existir.

Nenhuma parte do RPC, de `admin-change-actions` ou de
`enqueue_no_show_balance_cancellation()` é alterada pelo Item 1.
