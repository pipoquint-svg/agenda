# Adicionais pós-reserva e saldo dinâmico

## Modelo

`appointments.commercial_value` permanece como o contrato original. Cada lançamento posterior fica em `appointment_post_booking_extras`, com tipo, quantidade, unidade, preço unitário e total congelados, administrador, horário, origem e chave idempotente. O saldo autoritativo é o valor original mais os lançamentos posteriores, menos a cobertura financeira já aprovada ou aplicada. O resumo financeiro, o estado de pagamento, o excedente devolvível e a lista de saldos abertos usam esse total.

Tempo extra usa a cotação original persistida no checkout ou na pré-reserva; para reservas antigas sem essa cotação, usa os snapshots de preço e duração da reserva se não houve remarcação. Se uma reserva remarcada não tem cotação original recuperável, a operação falha com `ORIGINAL_PRICE_SNAPSHOT_MISSING` em vez de inventar uma tarifa. Não há chamada ao motor de disponibilidade, aos intervalos ou às políticas de agenda. Assistência e cobertura usam o preço por hora vigente do catálogo e preservam um snapshot por lançamento; sua quantidade representa horas.

Uma cobrança `PENDING` continua com o mesmo identificador e os mesmos tokens PAY. A abertura do link consulta o saldo atual. Se o saldo anterior era zero ou a cobrança expirou, nasce uma cobrança `POST_BOOKING_EXTRA` e um único job de e-mail. O trabalhador de e-mail gera um segredo de 256 bits no fragmento do URL; o banco guarda só o hash. Links antigos com `collection` continuam usando a validação de e-mail e recebem um token PAY interno.

Se há transação PIX/cartão pendente quando o saldo muda, a cobrança marca `provider_refresh_pending`. O endpoint de pagamento bloqueia novos intents e retries antigos enquanto o adaptador cancela as ordens antigas no Mercado Pago. Após cancelamento, os intents pendentes expiram e o mesmo link pode criar um pagamento FULL com o saldo atual. Falha de cancelamento mantém o bloqueio e registra divergência; a operação administrativa pode ser repetida com a mesma chave sem lançar o adicional novamente.

## Publicação e reversão

Ordem: migration; Edge Functions `admin-appointment-edit`, `balance-collection-provider-cancel`, `balance-collection-notify-email`, `mercado-pago-payment`; frontend BlackSheep. Antes da migration em produção, obter backup lógico verificável do esquema e das tabelas financeiras afetadas. Não remover a migration em produção: para reverter o comportamento, voltar Edge/frontend à versão anterior e desabilitar a ação de lançamento. Os lançamentos já realizados permanecem auditáveis; uma reversão de banco que os ignorasse exige conciliação de pagamentos antes de ser considerada.

Verificação sem cobrança real: em ambiente de preview, criar reserva de teste quitada, lançar 30 minutos, confirmar um job de e-mail e abrir o link mágico; testar um saldo pendente com link legado, e simular cancelamento de ordem em provedor de teste antes de abrir novo checkout. Não aprovar um pagamento real durante a verificação.
