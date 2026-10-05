# Adicionais pós-reserva e saldo dinâmico

## Modelo

`appointments.commercial_value` permanece como o contrato original. Cada lançamento posterior fica em `appointment_post_booking_extras`, com tipo, quantidade, unidade, preço unitário e total congelados, administrador, horário, origem e chave idempotente. O saldo autoritativo é o valor original mais os lançamentos posteriores, menos a cobertura financeira já aprovada ou aplicada. O resumo financeiro, o estado de pagamento, o excedente devolvível e a lista de saldos abertos usam esse total.

Tempo extra usa a cotação original persistida no checkout ou na pré-reserva; para reservas antigas sem essa cotação, usa os snapshots de preço e duração da reserva se não houve remarcação. Se uma reserva remarcada não tem cotação original recuperável, a operação falha com `ORIGINAL_PRICE_SNAPSHOT_MISSING` em vez de inventar uma tarifa. Não há chamada ao motor de disponibilidade, aos intervalos ou às políticas de agenda. Assistência e cobertura usam o preço por hora vigente do catálogo e preservam um snapshot por lançamento; sua quantidade representa horas.

Uma cobrança `PENDING` continua com o mesmo identificador e os mesmos tokens PAY. A abertura do link consulta o saldo atual. Se o saldo anterior era zero ou a cobrança expirou, nasce uma cobrança `POST_BOOKING_EXTRA` e um único job de e-mail. O trabalhador de e-mail gera um segredo de 256 bits no fragmento do URL; o banco guarda só o hash. Links antigos com `collection` continuam usando a validação de e-mail e recebem um token PAY interno.

Se há transação PIX/cartão pendente quando o saldo muda, a cobrança marca `provider_refresh_pending`. O endpoint de pagamento bloqueia novos intents e retries antigos enquanto o adaptador cancela as ordens antigas no Mercado Pago. Após cancelamento, os intents pendentes expiram e o mesmo link pode criar um pagamento FULL com o saldo atual. Falha de cancelamento mantém o bloqueio e registra divergência; a operação administrativa pode ser repetida com a mesma chave sem lançar o adicional novamente.

## Publicação e reversão

Ordem: migration; Edge Functions `admin-appointment-edit`, `balance-collection-provider-cancel`, `balance-collection-notify-email`, `mercado-pago-payment`; frontend BlackSheep. Antes da migration em produção, obter backup lógico verificável do esquema e das tabelas financeiras afetadas. Não remover a migration em produção: para reverter o comportamento, voltar Edge/frontend à versão anterior e desabilitar a ação de lançamento. Os lançamentos já realizados permanecem auditáveis; uma reversão de banco que os ignorasse exige conciliação de pagamentos antes de ser considerada.

## Resultado da publicação

O backup lógico protegido foi concluído no [run 37343795196](https://github.com/pipoquint-svg/agenda/actions/runs/37343795196), antes da migração. A Agenda foi publicada no SHA `d3bb4008bf4c20716d418cb982b34fbabb8627de` pelo [run 37345679703](https://github.com/pipoquint-svg/agenda/actions/runs/37345679703); o banco confirma a migration `20261005150444`, a nova tabela e os RPCs, e as quatro funções estão ativas. A interface BlackSheep foi publicada no SHA `282b574d9f4ec0788b16edc82bdd5304acf7eb1b` pelo Lovable, deployment `3304cecd-2037-4494-8c57-674765321ca5`.

O [CI pós-publicação](https://github.com/pipoquint-svg/black-sheep/actions/runs/37349125380) passou QA, quatro suítes integradas e smoke. O E2E criou uma reserva quitada e uma cotação original no Supabase local descartável; pela interface, lançou dois blocos de 30 minutos, confirmou uma única collection e abriu o mesmo magic link com saldo atualizado. Não gerou PIX ou cartão. O razão de adicionais em produção permaneceu vazio durante a verificação. Links legados, PAY-only, idempotência e bloqueio de ordem antiga têm testes de banco e frontend; o cancelamento não foi provocado em uma ordem real do Mercado Pago. O Supabase Preview remoto foi pulado por limite de branches ativas; a verificação integrada ocorreu localmente.
