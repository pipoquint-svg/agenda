# Mercado Pago — gate de produção

Data da revisão: 2026-08-30.

## Regra de go-live

Cobranças reais não devem ser habilitadas até que a conta oficial do estúdio e as credenciais de produção do Mercado Pago estejam certificadas. O gate `ALLOW_REAL_CHARGES` deve permanecer desligado enquanto qualquer item externo abaixo estiver pendente.

## Conta oficial — evidência obrigatória

Antes de habilitar cobranças reais, confirmar no painel oficial do Mercado Pago:

- CNPJ correto do estúdio;
- titular/razão social corretos;
- conta bancária/destino de recebimento correto;
- aplicação oficial usada pela BlackSheep;
- credencial de produção dessa aplicação;
- webhook de produção da aplicação apontando para o Supabase oficial `sbexdggbwqvyhbkatucs`;
- chave secreta do webhook correspondente ao ambiente de produção.

Não considerar prints antigos, credenciais de usuário de teste, conta pessoal ou sandbox como evidência de produção.

## Estado técnico certificado no backend

- PIX e cartão são suportados pelo `mercado-pago-payment`.
- Criação de cobrança usa idempotência e falha fechada para cobrança real sem autorização explícita.
- Webhook valida assinatura HMAC e reconcilia o estado consultando a API do Mercado Pago.
- Eventos repetidos são idempotentes no banco por `(provider,event_key)` e por `provider_event_id`.
- `APPROVED` confirma a reserva e encerra o hold.
- `REJECTED` e `EXPIRED` expiram a reserva em `AWAITING_PAYMENT/HELD` e liberam o recurso.
- Checkout hold atual da BlackSheep: 10 minutos.
- Payment hold atual da BlackSheep: 30 minutos.
- O worker executa a limpeza de holds expirados; a execução agendada é periódica, então a liberação física pode ocorrer no ciclo seguinte.
- Reembolso via Mercado Pago exige `FINANCE_MANAGE`, usa idempotência, valida a resposta do provedor e grava auditoria/estado financeiro.
- Cancelamento libera o horário; um reembolso posterior não reabre a reserva cancelada.

## Itens que continuam bloqueando produção

1. Certificar conta oficial, CNPJ, titular e destino bancário.
2. Instalar a credencial de produção correta nos Edge Function secrets do Supabase oficial.
3. Remover credenciais de sandbox dos secrets hospedados e, após a certificação live, retirar os caminhos de sandbox que deixarem de ser necessários no repositório.
4. Configurar e testar o webhook de produção do lado do Mercado Pago, incluindo um pagamento aprovado real controlado.
5. Executar smoke real controlado de PIX e cartão de crédito.
6. Executar casos reais/controlados de recusado, pendente/expirado e reembolso.
7. Conferir no painel oficial onde o dinheiro fica disponível e o prazo de recebimento contratado para a conta.

## Critério para virar `ALLOW_REAL_CHARGES`

Somente depois que os sete itens acima tiverem evidência. A ativação deve ser seguida por um teste pequeno e controlado; se webhook, confirmação da reserva ou conciliação financeira divergirem, desligar o gate e investigar antes de aceitar reservas públicas.
