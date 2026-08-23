# Mercado Pago Sandbox Gate — Orders API

Status inicial: `NÃO TESTADO`.

Este runbook fecha o gate remoto do issue #73. Ele deve ser executado **somente com credenciais de TESTE** antes de qualquer credencial de produção.

## 1. Configuração de teste

No Mercado Pago Developers, abra a aplicação da Agenda e use as **Credenciais de teste** da integração Checkout Transparente.

Configure fora do repositório:

### Frontend

`VITE_MERCADO_PAGO_PUBLIC_KEY`

Valor: Public Key de TESTE.

### Supabase Edge Function Secrets

`MERCADO_PAGO_ACCESS_TOKEN`

Valor: Access Token de TESTE.

`MERCADO_PAGO_WEBHOOK_SECRET`

Valor: secret/signature secret gerado na configuração de Webhooks da aplicação.

`MERCADO_PAGO_WEBHOOK_URL`

Valor:

`https://<PROJECT_REF>.supabase.co/functions/v1/mercado-pago-webhook`

Nunca registrar Access Token ou webhook secret em issue, PR, commit, screenshot ou chat.

## 2. Modelo de integração

A Agenda usa a **Orders API** do Mercado Pago:

- criação: `POST /v1/orders`;
- consulta/reconciliação: `GET /v1/orders/{order_id}`;
- `processing_mode=automatic`;
- uma cobrança interna da Agenda corresponde a exatamente **uma Order com uma transação de pagamento**;
- o `external_reference` da Order deve ser o UUID da transação interna;
- o campo interno legado `provider_payment_id` guarda o **Order ID** durante a V1 para evitar migração estrutural desnecessária.

Payments API (`/v1/payments`) e o evento `Pagamentos (legacy)` não fazem parte do gate atual.

## 3. Webhook

Na aplicação Mercado Pago, configure a URL de **Modo de teste** e selecione o evento **Order (Mercado Pago)**.

A integração deve exigir:

- `x-signature` válida;
- `x-request-id`;
- `data.id` da Order;
- consulta da Order em `GET /v1/orders/{id}` antes de alterar a reserva;
- vínculo exato entre Order e intenção interna por `external_reference`, valor, método e cardinalidade da transação;
- evento `live_mode=true` ignorado no sandbox;
- evento de teste ignorado em eventual ambiente de produção.

Webhook inválido nunca pode alterar estado financeiro.

## 4. PIX

A criação PIX deve usar uma única transação:

- `payment_method.id = pix`;
- `payment_method.type = bank_transfer`.

O cliente pode receber temporariamente `qr_code`, `qr_code_base64` e `ticket_url`. Esses dados não devem ser persistidos na Agenda.

Order/Payment em estado de ação pendente nunca confirma a reserva. A confirmação depende da reconsulta assinada/polling resultar em estado aprovado/processado.

## 5. Cartão e 3DS

Dados brutos do cartão nunca passam pelo backend; a Agenda recebe somente o token do SDK Mercado Pago.

Para 3DS, a Order usa `config.online.transaction_security`. Quando houver challenge:

- o provedor pode responder `action_required` / `pending_challenge`;
- a URL vem em `transactions.payments[0].payment_method.transaction_security.url`;
- o navegador abre somente URL HTTPS no iframe;
- mensagem `COMPLETE` do iframe é apenas um sinal para reconsultar a Order;
- o navegador nunca confirma pagamento sozinho;
- a URL de challenge não deve ser persistida.

## 6. Matriz obrigatória

| Cenário | Resultado esperado |
| --- | --- |
| PIX criado | Order única + transação única + QR/copia e cola, sem confirmar antes de aprovação |
| PIX aprovado/processado | pagamento aplicado uma vez; reserva confirma ao atingir o alvo contratual |
| PIX pendente/action_required | reserva continua pendente |
| PIX expirado/rejeitado/cancelado | não confirma e não liquida contrato |
| Cartão aprovado/processado | aplica exatamente uma vez |
| Cartão rejeitado/falho | não confirma e permite nova tentativa válida |
| Cartão 3DS challenge | iframe HTTPS abre URL do provedor; browser não confirma sozinho |
| 3DS aprovado | somente Order reconsultada/webhook confirma |
| 3DS falho | reserva não confirma |
| Mesma request key repetida | não cria cobrança interna duplicada |
| Webhook duplicado | aplicação idempotente |
| Webhook com assinatura inválida | HTTP 401 e nenhuma mutação |
| Order ID incompatível | quarentena; nenhuma confirmação |
| `external_reference` incompatível | quarentena; nenhuma confirmação |
| Valor incompatível | quarentena; nenhuma confirmação |
| Método incompatível | quarentena; nenhuma confirmação |
| Order com múltiplas transações | quarentena; nenhuma confirmação |
| Evento live no sandbox | reconhecido/ignorado, nenhuma mutação |
| Reserva expirada antes do pagamento | horário liberado |
| Pagamento aprovado depois da expiração | incidente financeiro; horário não volta a confirmar automaticamente |

## 7. Evidência mínima

Para cada cenário registrar **sem dados sensíveis**:

- data/hora;
- cenário;
- código público da reserva ou UUID interno quando apropriado;
- Order ID Mercado Pago;
- ID da transação do provedor quando útil e não sensível;
- estado da transação interna;
- estado da reserva;
- resultado do webhook/polling;
- PASS/FAIL;
- observação curta.

Não registrar token de acesso da reserva, Access Token, webhook secret, CPF, e-mail completo, dados de cartão, token de cartão, QR PIX ou URL 3DS.

## 8. Critérios de aprovação

`SANDBOX TESTED` somente quando toda a matriz obrigatória passar em ambiente remoto usando credenciais de teste e Orders API.

`LIVE APPROVED` exige, além do sandbox verde:

1. troca controlada para credenciais de produção;
2. URL/evento de webhook de produção revisados;
3. secrets de produção configurados somente no ambiente;
4. smoke test de baixo risco explicitamente autorizado pelo responsável financeiro;
5. confirmação de que nenhum dado sensível foi persistido ou exposto;
6. issue #73 atualizado com evidências e decisão explícita de liberação.

Até isso ocorrer, o estado deve permanecer `LIVE APPROVED: NÃO`.
