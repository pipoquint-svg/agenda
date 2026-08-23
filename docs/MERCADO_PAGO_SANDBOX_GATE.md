# Mercado Pago Sandbox Gate

Status inicial: `NÃO TESTADO`.

Este runbook fecha o gate remoto do issue #73. Ele deve ser executado **somente com credenciais de TESTE** antes de qualquer credencial de produção.

## 1. Configuração de teste

No Mercado Pago Developers, abra a aplicação da Agenda e use as **Credenciais de teste**.

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

## 2. Webhook

Na aplicação Mercado Pago, configure a URL de **teste** para receber eventos de pagamento.

A integração deve exigir:

- `x-signature` válida;
- `x-request-id`;
- consulta do pagamento em `GET /v1/payments/{id}` antes de alterar a reserva;
- vínculo exato entre pagamento do provedor e intenção interna por `external_reference`, valor e método.

Webhook inválido não pode alterar estado financeiro.

## 3. Matriz obrigatória

| Cenário | Resultado esperado |
| --- | --- |
| PIX criado | intenção interna única + QR/copia e cola, sem confirmar antes de `approved` |
| PIX aprovado | pagamento aplicado uma vez; reserva confirma ao atingir o alvo contratual |
| PIX pendente | reserva continua pendente |
| PIX expirado/rejeitado | não confirma e não liquida contrato |
| Cartão aprovado | aplica exatamente uma vez |
| Cartão rejeitado | não confirma e permite nova tentativa válida |
| Cartão 3DS challenge | iframe HTTPS recebe `creq`; browser não confirma sozinho |
| 3DS aprovado | somente status reconsultado/webhook confirma |
| 3DS falho | reserva não confirma |
| Mesma request key repetida | não cria cobrança interna duplicada |
| Webhook duplicado | aplicação idempotente |
| Webhook com assinatura inválida | HTTP 401 e nenhuma mutação |
| Payment ID incompatível | quarentena; nenhuma confirmação |
| `external_reference` incompatível | quarentena; nenhuma confirmação |
| Valor incompatível | quarentena; nenhuma confirmação |
| Método incompatível | quarentena; nenhuma confirmação |
| Reserva expirada antes do pagamento | horário liberado |
| Pagamento aprovado depois da expiração | incidente financeiro; horário não volta a confirmar automaticamente |

## 4. Evidência mínima

Para cada cenário registrar **sem dados sensíveis**:

- data/hora;
- cenário;
- código público da reserva ou UUID interno quando apropriado;
- ID do pagamento Mercado Pago, se não contiver dado pessoal;
- estado da transação interna;
- estado da reserva;
- resultado do webhook/polling;
- PASS/FAIL;
- observação curta.

Não registrar token de acesso da reserva, Access Token, Public Key junto com credenciais privadas, webhook secret, CPF, e-mail completo, dados de cartão, QR PIX ou `creq` 3DS.

## 5. Critérios de aprovação

`SANDBOX TESTED` somente quando toda a matriz obrigatória passar em ambiente remoto usando credenciais de teste.

`LIVE APPROVED` exige, além do sandbox verde:

1. troca controlada para credenciais de produção;
2. URL de webhook de produção revisada;
3. secrets de produção configurados somente no ambiente;
4. smoke test de baixo risco autorizado pelo responsável financeiro;
5. confirmação de que nenhum dado sensível foi persistido ou exposto;
6. issue #73 atualizado com evidências e decisão explícita de liberação.

Até isso ocorrer, o estado deve permanecer `LIVE APPROVED: NÃO`.
