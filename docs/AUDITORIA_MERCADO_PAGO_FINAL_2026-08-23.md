# Auditoria final — implantação Mercado Pago Sandbox

Data: 23/08/2026  
Projeto: Agenda BlackSheep  
Escopo: integração Mercado Pago Checkout Transparente / Orders API, sandbox, cartão, PIX, webhook, idempotência e jornada financeira interna.

## 1. Estado final de evidência

| Camada | Estado | Evidência |
|---|---|---|
| `IMPLEMENTED` | YES | Orders API consolidada na `main`; payment + webhook + helpers + migrations |
| `CI PASS` | YES | `Database Core` e `Demand Capture` verdes no PR final de correção |
| `SANDBOX TESTED` | YES para provider/backend | Orders API, PIX, webhook/HMAC, cartão aprovado/recusado, jornada Agenda e replay idempotente |
| `STAGING TESTED` | PARTIAL/NO para browser | Browser tokenization em origem representativa ainda não foi aprovado; harnesses temporários foram aposentados |
| `LIVE APPROVED` | NO | produção não autorizada nem testada |

`SANDBOX TESTED = YES` neste documento significa **provider/backend e jornada financeira interna**, não browser real, 3DS ou produção.

## 2. Resultado final autônomo

O teste final foi executado sem dados reais, sem cartão real e sem presença do usuário.

### 2.1 Cartão aprovado — jornada Agenda

Fluxo real executado:

`fixture sintética Agenda -> token de cartão sandbox -> mercado-pago-payment -> POST /v1/orders -> validação do Order -> apply_provider_payment_status -> appointment`

Resultado:

- CardToken sandbox: criado;
- Order: `ORDTST01M0PC80CZ52F7130B8657R1TB`;
- Order/provider: `processed / accredited`;
- resposta pública normalizada: `approved / accredited`;
- pagamento interno: `APPROVED`;
- valor em dinheiro: R$ 50,00;
- valor do contrato liquidado: R$ 50,00;
- reserva: `CONFIRMED`;
- financeiro: `PARTIALLY_PAID`;
- nenhum dado bruto de cartão foi persistido ou impresso.

### 2.2 Cartão recusado — jornada Agenda

Fluxo real executado com cenário oficial `OTHE`.

Resultado:

- CardToken sandbox: criado;
- Mercado Pago: HTTP `402`;
- provider error: `failed`;
- API Agenda: `MERCADO_PAGO_PAYMENT_REJECTED`;
- pagamento interno: `REJECTED`;
- reserva permaneceu `AWAITING_PAYMENT`;
- `confirmed_at` permaneceu nulo;
- nenhum valor foi considerado pago.

### 2.3 Replay idempotente

A mesma chave lógica da tentativa aprovada foi reapresentada após a confirmação.

Resultado:

- `idempotent_replay = true`;
- mesma transação interna;
- mesma Order `ORDTST01M0PC80CZ52F7130B8657R1TB`;
- continuou `approved / accredited`;
- quantidade de transações internas permaneceu `1`;
- nenhuma segunda cobrança foi criada.

## 3. Achados cronológicos

### Erro 1 — integração começou na Payments API

A primeira implementação foi construída em `/v1/payments` e evento `payment`, enquanto a integração atual da aplicação estava orientada a `Order (Mercado Pago)`.

**Classe:** arquitetura / source of truth incorreto.

**Correção:** migração para `/v1/orders`, GET de Order, evento Order e validação server-side.

**Lição:** escolher primeiro o produto/API/evento atual do fornecedor; somente depois escrever integração.

### Erro 2 — mensagem `Unauthorized use of live credentials` foi interpretada no contexto errado

A investigação inicial tentou corrigir credencial/escopo dentro da Payments API.

**Classe:** diagnóstico parcial.

**Correção:** preflight read-only migrou para a Orders API, a superfície realmente utilizada.

**Lição:** mensagem do fornecedor não substitui a validação de produto, endpoint, versão e ambiente.

### Erro 3 — Supabase project ref foi transcrito incorretamente

Um caractere ausente alterou project ref e URL do webhook.

**Classe:** configuração/transcrição.

**Correção:** ref e URL corrigidos.

**Lição:** IDs de infraestrutura precisam de validação programática; não copiar manualmente sem gate.

### Erro 4 — deploy foi automatizado antes de o contrato externo estabilizar

O deploy seguro já possuía boas travas, mas automatizou uma arquitetura ainda em mudança.

**Classe:** sequenciamento.

**Lição:** `spike real -> contrato mínimo -> automação`, não o inverso.

### Erro 5 — busca de Orders exigia parâmetros não capturados inicialmente

`GET /v1/orders` necessitava filtros temporais no fluxo adotado.

**Classe:** contrato de API incompleto.

**Lição:** registrar requisição mínima real — método, endpoint, headers, parâmetros obrigatórios e resposta — antes da abstração.

### Erro 6 — cartão comum e 3DS foram misturados no primeiro gate

Cenários comuns e cenários de autenticação foram tratados como uma única prova.

**Classe:** desenho de teste.

**Correção:** APRO/OTHE comuns separados de 3DS.

### Erro 7 — Playwright selecionou input interno/oculto

O primeiro harness de CardForm dependia de seletores genéricos.

**Classe:** automação browser frágil.

**Correção:** secure fields explícitos.

### Erro 8 — harness aguardava issuer e parcelas desnecessários

A automação dependia de selects dinâmicos não necessários ao caso de uma parcela.

**Classe:** complexidade criada pelo teste.

**Correção:** retirada da dependência.

### Erro 9 — CardForm preenchia, mas não entregava token no submit headless

O comportamento real não foi reproduzido pelo harness.

**Classe:** inadequação do harness.

### Erro 10 — Card Payment Brick não montou no runner

Mesmo após substituir CardForm pelo Brick, `onReady` não ocorreu.

**Classe:** inadequação do ambiente.

### Erro 11 — diagnóstico finalmente provou que localhost/headless não representava o browser real

Run `32614465013` mostrou CORS, ORB, 403/404, `controllerCreated=false` e ausência de campos.

**Classe:** ambiente de teste não representativo.

**Decisão correta:** interromper patches incrementais e aposentar o harness como evidência autoritativa.

### Erro 12 — Public Key foi classificada incorretamente pelo prefixo

Durante o diagnóstico, uma Public Key de teste com prefixo `APP_USR-...` foi confundida com Access Token. O painel da própria aplicação mostrou que aquela credencial era a Public Key.

**Classe:** inferência não validada.

**Lição:** nunca classificar credencial somente por prefixo. A fonte autoritativa é o painel/contrato específico da aplicação e o campo em que a credencial foi emitida.

### Erro 13 — browser raw.githack conseguiu montar campos, mas tokenização retornou `Failed to fetch`

O log do Supabase comprovou que nenhum POST chegou ao backend. A falha ocorreu antes da Order, durante a tokenização client-side.

**Classe:** camada browser/provider.

**Decisão:** não usar essa página como prova da integração financeira; provider/backend foi validado separadamente e o browser permanece gate próprio.

### Erro 14 — Orders API estava validada no sandbox, mas não consolidada na `main`

A auditoria final encontrou `mercado-pago-payment` da `main` ainda em `/v1/payments`. O código Orders estava em cadeia de branches/PRs, porque PR #93 fora mergeado sobre branch de hardening, não diretamente na `main`.

**Classe:** drift de branch / promoção incompleta.

**Correção:** PR #105 consolidou na `main`:

- saldo e liquidação;
- migrations financeiras;
- Orders API;
- webhook Order;
- helpers;
- frontend de pagamento;
- testes correspondentes.

Depois da consolidação, busca por `api.mercadopago.com/v1/payments` na `main` não encontrou uso ativo da API legacy.

**Lição:** `MERGED` não significa `RELEASE BRANCH CONTAINS`. Todo fechamento precisa provar ancestralidade/presença no branch autoritativo.

### Erro 15 — cartão comum da Agenda ainda forçava 3DS

No teste integrado final, APRO retornou:

- `action_required`;
- `pending_challenge`.

A causa estava no backend: toda Order de cartão recebia:

`config.online.transaction_security.validation = on_fraud_risk`.

A documentação atual do Mercado Pago define que, sem esse nó, o comportamento default é `validation=never`; o nó é parte da integração 3DS.

**Classe:** mistura de capacidades no código produtivo.

**Correção:** PR #106 separou cartão comum de 3DS. O modo 3DS passou a depender explicitamente de `MERCADO_PAGO_3DS_MODE=on_fraud_risk`; default = sem 3DS.

**Lição:** capacidades com gates diferentes não devem compartilhar ativação implícita.

### Erro 16 — replay de idempotência podia virar falsa rejeição

O teste integrado inicial sofreu retry após a primeira Order ser aceita. Mercado Pago respondeu a repetição com:

`409 idempotency_key_already_used`.

O backend tratava qualquer não-2xx abaixo de 500 como rejeição e executava `service_fail_payment_intent`, convertendo uma transação existente em `REJECTED`.

**Classe:** state machine / idempotência.

**Correção:** PR #106:

- se o intent é replay e já possui Order, faz GET da Order e reaplica seu estado;
- `409 idempotency_key_already_used` nunca é tratado como rejeição financeira;
- se ainda não houver vínculo local suficiente para recuperar a Order, retorna falha temporária sem destruir o intent.

**Prova:** replay final retornou a mesma Order aprovada e permaneceu com uma única transação interna.

### Erro 17 — ferramentas temporárias criaram drift de infraestrutura durante o diagnóstico

A depuração instalou temporariamente extensões HTTP no banco e gerou duas entradas de migration history fora do repositório.

**Classe:** higiene de ambiente de teste.

**Correção final:**

- migrations temporárias removidas do histórico;
- `http` e `pg_net` removidos após o teste;
- fixtures sintéticas removidas;
- endpoint temporário de cartão tombstonado;
- browser harnesses e página rawgithack removidos do repositório.

**Lição:** todo probe temporário deve ter teardown explícito como parte da própria definição de sucesso.

## 4. O que os testes verdes realmente provam

O workflow `Database Core` inclui testes locais de helpers de Google, WhatsApp e Mercado Pago. Eles são válidos, mas não equivalem a fornecedor testado.

Adotar rótulo de evidência por suíte:

- `LOCAL_CONTRACT`;
- `DATABASE_CONTRACT`;
- `PROVIDER_SANDBOX`;
- `STAGING_BROWSER`;
- `END_TO_END`;
- `LIVE`.

CI verde deve sempre declarar a camada que prova.

## 5. pgTAP — conclusão correta

O caso `006_change_policy` tinha plano 20 para 19 asserts e foi detectado pelo próprio gate `supabase test db`. Portanto, não foi um falso verde silencioso.

O aprendizado é outro:

- um plano consistente prova apenas que o número executado corresponde ao plano;
- não prova que a semântica testada representa a regra de negócio correta;
- fixtures e expectativas ainda precisam de revisão de sentido, especialmente em política, saldo e liquidação.

## 6. Regras permanentes derivadas

### 6.1 Duas provas obrigatórias

Uma integração externa só avança quando houver prova de:

1. **contrato real do fornecedor**;
2. **representatividade do ambiente/harness para a camada testada**.

### 6.2 Failure Budget

Após duas falhas consecutivas no mesmo gate externo:

1. parar patches;
2. classificar em código, contrato, credencial, ambiente ou fornecedor;
3. reabrir source of truth;
4. provar que o harness representa produção;
5. executar spike mínimo alternativo;
6. só então alterar código novamente.

### 6.3 Estados de evidência

1. `IMPLEMENTED`
2. `CI PASS`
3. `SANDBOX TESTED`
4. `STAGING TESTED`
5. `LIVE APPROVED`

`PARTIAL` deve listar exatamente o que foi provado.

### 6.4 Pipeline obrigatório

`Source of Truth -> Spike -> Provider Sandbox -> Staging HTTPS -> Jornada E2E -> Live`

### 6.5 Branch autoritativo

Todo fechamento deve responder:

- o código está na branch autoritativa?
- migrations do ambiente estão representadas no repositório?
- Edge Function implantada corresponde ao SHA/branch esperados?
- PR mergeado em branch intermediária foi efetivamente promovido?

### 6.6 Teardown obrigatório

Todo artefato de teste temporário deve ter plano de retirada:

- fixtures;
- extensões;
- páginas;
- probes públicos;
- workflows temporários;
- secrets temporários;
- migrations de diagnóstico.

## 7. Situação por capacidade

### Orders API

`PROVIDER_SANDBOX: PASS`

### PIX

`PROVIDER_SANDBOX: PASS`

Inclui criação, consulta e idempotência.

### Webhook Order / HMAC

`PROVIDER_SANDBOX: PASS`

### Cartão comum

`PROVIDER_SANDBOX: PASS`  
`AGENDA_BACKEND_E2E: PASS`

Inclui APRO, OTHE e replay idempotente.

### Browser tokenization

`STAGING_BROWSER: NÃO APROVADO`

Não usar resultados dos harnesses aposentados como aprovação.

### 3DS

`NÃO TESTADO`

A arquitetura preserva suporte a challenge, mas ativação fica separada por gate.

### Produção

`LIVE APPROVED: NO`

Nenhuma credencial, charge ou cliente real foi utilizado para esta aprovação.

## 8. Dependência que permanece aberta

Staging HTTPS autoritativo continua necessário para:

- tokenização de cartão no frontend real;
- 3DS/challenge;
- Safari/Chrome em dispositivo;
- OAuth Google e redirect URI real;
- cookies, CORS, popup/iframe e redirects.

Esse bloqueador permanece no Gate #73 / issue de staging. A prova backend do Mercado Pago não elimina essa necessidade.

## 9. Referências internas principais

- #73 — gate de integrações/live;
- #89–#101 — sequência de sandbox/hardening/diagnóstico;
- #105 — consolidação Orders API e liquidação na `main`;
- #106 — separação cartão/3DS + recuperação idempotente;
- #107 — limpeza dos harnesses temporários;
- #102 — staging HTTPS autoritativo.

## 10. Conclusão

O Mercado Pago deixou de ser um conjunto de suposições cobertas por CI local e passou a ter evidência real de provider/backend no sandbox.

A lição principal não é específica do Mercado Pago:

> Uma integração externa só pode ser declarada comprovada quando o contrato real do fornecedor foi exercitado e quando o ambiente usado representa a camada que está sendo aprovada.

E uma terceira obrigação foi adicionada após a auditoria final:

> Código validado fora da branch autoritativa não está consolidado; todo fechamento precisa provar promoção, estado implantado e teardown dos artefatos temporários.
