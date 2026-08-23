# Auditoria da integração Mercado Pago no sandbox

Data de consolidação: 23/08/2026

Status: documento de auditoria. Não equivale a `SANDBOX TESTED` completo nem a `LIVE APPROVED`.

Escopo: reconstruir as falhas, decisões, correções e aprendizados observados desde o início da implantação real do Mercado Pago na Agenda BlackSheep, com foco em distinguir erro de código, erro de arquitetura, hipótese documental e limitação do ambiente de teste.

## 1. Resumo executivo

A integração não falhou como um todo. O backend do Mercado Pago via Orders API já possui evidências positivas no sandbox para credencial, preflight read-only, deploy remoto, webhook Order, HMAC, criação de PIX, consulta da Order e idempotência do provedor.

O principal gate ainda aberto é cartão browser-side, seguido de 3DS e jornada financeira end-to-end da Agenda.

O problema central desta implantação foi metodológico: código e automações avançaram antes de o contrato real do fornecedor estar suficientemente provado no ambiente correto. No cartão, várias correções sucessivas foram feitas em um harness headless do GitHub Actions até que a execução 32614465013 demonstrou que o próprio ambiente `http://127.0.0.1:<porta>` do runner não reproduzia adequadamente o contexto necessário para o Card Payment Brick.

Conclusão operacional: não executar novo patch incremental no Card Gate headless. A validação de cartão deve migrar para o checkout real da Agenda em staging HTTPS, usando credenciais e dados sintéticos de teste.

## 2. Linha do tempo de erros e soluções

### 2.1 Integração inicial baseada em Payments API

Situação inicial:

- criação e probe em `/v1/payments`;
- webhook orientado a `payment`;
- desenho de teste inspirado na Payments API.

Problema: no painel atual da aplicação, `Order (Mercado Pago)` era o evento coerente com o Checkout Transparente atual, enquanto `Pagamentos` aparecia como legacy.

Correção: PR #93 migrou a integração para Orders API:

- `POST /v1/orders`;
- `GET /v1/orders/{id}`;
- PIX como `bank_transfer/pix`;
- cartão como `credit_card` tokenizado;
- webhook `Order`;
- reconsulta server-side da Order antes de mutação financeira;
- quarentena de mismatches e idempotência preservadas.

Classificação: erro de arquitetura / seleção da superfície errada do fornecedor.

Aprendizado: antes de implementar, congelar produto, API, evento e documentação canônica da integração.

### 2.2 `401 Unauthorized use of live credentials` em credencial de teste

O probe pela Payments API retornou 401 mesmo com credencial copiada da área de testes.

Correção intermediária: PR #92 substituiu o POST por preflight read-only em `GET /v1/payments/search` para não criar cobrança durante o diagnóstico.

Limitação dessa correção: ela reduziu risco, mas continuou validando a família de API que depois deixou de ser o alvo.

Correção estrutural: após a migração para Orders, o preflight passou para `GET /v1/orders`.

Classificação: mensagem do fornecedor potencialmente enganosa + diagnóstico parcial nosso.

Aprendizado: não tratar a mensagem textual da API como causa raiz antes de validar endpoint, produto, escopo e integração correta.

### 2.3 Reference ID incorreto do Supabase sandbox

O workflow inicial usava um Reference ID transcrito com um caractere ausente e, por consequência, URL de webhook incorreta.

Correção: PR #90 ajustou o Reference ID e a URL pública da Edge Function.

Classificação: erro de transcrição/configuração.

Aprendizado: IDs de infraestrutura devem ser validados programaticamente; não confiar em transcrição manual.

### 2.4 Workflow de deploy automatizado antes do contrato do provedor estabilizar

O PR #89 criou corretamente um deploy seguro com:

- confirmação `SANDBOX`;
- `APP_ENV=staging`;
- `MERCADO_PAGO_ENV=sandbox`;
- `ALLOW_REAL_CHARGES=false`;
- `ALLOW_REAL_CUSTOMER_DATA=false`;
- secrets fora do código;
- migrations;
- deploy de Edge Functions;
- boundary de assinatura do webhook.

Porém o workflow ainda estava acoplado ao modelo anterior de API/evento.

Correção: PR #95 alinhou o deploy à Orders API, ao evento `order`, ao preflight correto e aos secrets definitivos.

Classificação: sequenciamento inadequado.

Aprendizado: primeiro provar contrato mínimo do fornecedor; depois automatizar profundamente o deploy.

### 2.5 Parâmetros obrigatórios da busca de Orders

A busca read-only em Orders exigia filtros temporais obrigatórios.

Correção: PR #95 passou a enviar `begin_date` e `end_date`, além da paginação mínima.

Classificação: contrato de API não capturado na primeira tentativa.

Aprendizado: toda integração externa deve começar por uma requisição mínima reproduzível com método, endpoint, headers, parâmetros obrigatórios e resposta real registrados.

### 2.6 PIX via Orders API

O PR #96 criou gate isolado para PIX no sandbox.

Validado:

- Order fictícia de R$ 50,00;
- uma única transação `pix / bank_transfer`;
- estado inicial `action_required / waiting_transfer`;
- QR/ticket retornado sem ser impresso;
- `GET /v1/orders/{id}`;
- replay da mesma idempotency key devolvendo a mesma Order.

Resultado: provider-level PIX funcional no sandbox.

Classificação: evidência positiva.

Aprendizado: gates pequenos e isolados produzem diagnóstico muito melhor do que tentar provar a jornada inteira de uma vez.

## 3. Sequência específica do cartão

### 3.1 Gate inicial misturava cartão comum e 3DS

O PR #97 introduziu um Card Gate headless com MercadoPago.js/CardForm e cenários que misturavam conceitos de aprovação/recusa com autenticação.

Correção posterior:

- cenários comuns passaram para `APRO` e `OTHE`;
- `transaction_security` saiu do gate comum;
- 3DS foi separado como gate posterior.

Classificação: desenho de teste inadequado.

Aprendizado: cartão comum, recusa e 3DS são provas distintas.

### 3.2 Run 32613205538: input oculto de expiração

Causa: o Playwright varria inputs genericamente e confundiu o campo visível com input interno/oculto de expiração.

Correção: PR #98 passou a preencher os secure fields por containers/iframes explícitos.

Resultado: não chegou à criação da Order.

Classificação: erro de automação browser.

### 3.3 Run 32613510566: dependência desnecessária de issuer/parcelas

Causa: após preencher os campos seguros, o harness aguardava selects dinâmicos de issuer e installments.

Correção: PR #99 removeu essa dependência e fixou `installments=1` exclusivamente para o gate sandbox.

Resultado: ainda não houve prova end-to-end do cartão.

Classificação: complexidade desnecessária no teste.

### 3.4 Run 32613806231: CardForm não produziu token no submit headless

Causa observada: o formulário montava e era preenchido, mas o submit não entregava token no ambiente headless.

Correção: PR #100 abandonou o CardForm no gate e passou a usar Card Payment Brick, aproximando o teste do componente real do frontend.

Também corrigiu:

- `APRO` / `OTHE`;
- separação do 3DS;
- diagnóstico sanitizado.

Ponto de processo: esta deveria ter sido a última tentativa de reproduzir o componente browser-side em localhost headless antes de reavaliar o ambiente.

### 3.5 Run 32614277261: Card Payment Brick não sinalizou `onReady`

Causa observada: timeout de 45s antes de o Brick ficar pronto. Nenhuma Order foi criada.

Correção: PR #101 simplificou a inicialização e adicionou diagnóstico de console, page errors, requests falhos e inventário de campos.

Ponto de processo: a correção ainda assumia que o Brick deveria funcionar no contexto do runner; essa hipótese não estava provada.

### 3.6 Run 32614465013: ambiente headless inadequado finalmente identificado

O diagnóstico do PR #101 mostrou:

- `MercadoPago` carregado;
- `controllerCreated=false`;
- `ready=false`;
- `Bricks component initialization failed`;
- requests auxiliares com 404;
- chamadas auxiliares bloqueadas por CORS;
- requests bloqueados por ORB;
- resposta 403 em recurso auxiliar;
- nenhum campo do Brick renderizado.

Conclusão: nessa execução, o problema não era cartão, CPF, cenário `APRO`, JSON da Order, Access Token ou seletor. O próprio componente não conseguiu inicializar adequadamente no microservidor localhost do GitHub Actions.

Classificação: estratégia de ambiente de teste inadequada.

Decisão: descontinuar o Card Gate headless como prova autoritativa de integração browser-side.

## 4. O que já está validado

### 4.1 Infraestrutura

- Supabase sandbox disponível;
- migrations aplicadas;
- secrets segregados;
- Edge Functions publicadas;
- workflow de deploy com travas contra charge/dado real.

### 4.2 Mercado Pago provider-level

- acesso read-only à Orders API;
- criação de Order PIX;
- consulta de Order;
- idempotência do provider;
- QR/ticket retornado;
- webhook `Order`;
- boundary de assinatura;
- HMAC;
- evento live ignorado no sandbox quando aplicável.

### 4.3 Estado correto do gate

`IMPLEMENTED`: parcial/avançado.

`CI PASS`: sim nas frentes já consolidadas.

`SANDBOX TESTED`: parcial.

`LIVE APPROVED`: não.

## 5. O que continua não validado

- cartão aprovado no checkout real;
- cartão recusado no checkout real;
- 3DS challenge;
- 3DS aprovado/falho;
- liquidação completa de uma reserva sintética da Agenda após cartão;
- retry completo;
- pagamento aprovado após expiração;
- jornada completa em browsers/dispositivos prioritários.

Todos permanecem `NÃO TESTADO` até execução real. Ausência de erro ou inspeção estática não pode promovê-los.

## 6. Falhas metodológicas identificadas

### 6.1 Implementação antes do spike real

Foi escrito código relevante antes de existir prova mínima completa do contrato do fornecedor.

Nova regra: integração externa começa por spike pequeno e descartável ou isolado, não por implementação completa.

### 6.2 Documentação de produtos diferentes misturada

O ecossistema Mercado Pago possui documentação de Payments API, Checkout Bricks e Checkout Transparente/Orders API com contratos e exemplos distintos.

Nova regra: cada integração deve registrar uma única documentação canônica por produto/fluxo. Qualquer fonte de outra família precisa ser explicitamente justificada.

### 6.3 CI confundido com confiança excessiva

Embora o projeto tenha preservado formalmente `SANDBOX TESTED` separado de `CI PASS`, o código teoricamente correto ainda avançou demais antes da prova remota.

Nova regra: `IMPLEMENTED`, `CI PASS`, `SANDBOX TESTED` e `LIVE APPROVED` são estados independentes e sequenciais de evidência.

### 6.4 Harness usado para provar ambiente que ele não representava

O Playwright era útil para testar nossa automação, mas não era prova suficiente de que um componente financeiro client-side funcionaria em staging/produção.

Nova regra: OAuth, pagamento client-side, 3DS, redirects, cookies, CORS, popup e comportamento mobile exigem staging real HTTPS quando o fornecedor depende do ambiente do navegador.

### 6.5 Falhas sucessivas tratadas como bugs locais

Foram feitos múltiplos patches incrementais antes de reavaliar o desenho do teste.

Nova regra: após duas falhas consecutivas no mesmo gate externo, acionar `Failure Budget`:

1. parar novos patches;
2. classificar a falha;
3. reabrir a documentação canônica;
4. confirmar que o ambiente de teste representa produção;
5. executar spike alternativo;
6. só então alterar código novamente.

## 7. Protocolo recomendado para integrações externas

Fluxo obrigatório:

`Source of Truth -> Spike -> Provider Sandbox -> Staging HTTPS -> Jornada E2E -> Live`.

### Layer A - contrato local

- unitários;
- typecheck;
- parsing;
- validação de payload;
- idempotência interna.

### Layer B - banco

- constraints;
- RLS;
- concorrência;
- state machine.

### Layer C - provider API

- credencial real de teste;
- endpoint real;
- request mínima;
- resposta real.

### Layer D - webhook/callback

- evento real ou simulador oficial;
- assinatura;
- replay;
- mismatch;
- idempotência.

### Layer E - browser staging

- domínio HTTPS real;
- SDK/OAuth/Brick real;
- redirects;
- cookies;
- CORS;
- popups/iframes;
- mobile.

### Layer F - jornada completa

- entidade sintética interna;
- ação do usuário;
- fornecedor;
- retorno/webhook;
- estado interno final;
- compensação/erro.

Uma layer não aprova automaticamente a seguinte.

## 8. Aplicação imediata a Google e WhatsApp

### Google Calendar

Antes de implementar automação completa:

1. projeto Google e consent screen;
2. Client ID/segredo em ambiente de teste;
3. redirect URI HTTPS real;
4. usuário/calendário exclusivamente de teste;
5. OAuth real;
6. refresh/reconexão;
7. leitura mínima;
8. criação/alteração mínima;
9. watch/webhook;
10. somente depois integração com a Agenda.

Se o app OAuth estiver em `Testing`, não considerar refresh token de curta duração como operação aprovada.

### WhatsApp

Antes de automações completas:

1. app e número de teste;
2. recipient allowlist;
3. token;
4. envio mínimo;
5. webhook/challenge;
6. assinatura;
7. status de mensagem;
8. retry/idempotência;
9. somente depois fluxo operacional da Agenda.

## 9. Próxima ação do Mercado Pago

Não executar novo patch no Card Gate headless.

Próxima prova correta:

1. publicar o checkout real da Agenda em staging HTTPS;
2. usar credenciais de teste do Mercado Pago;
3. usar dados e cartões sintéticos oficiais;
4. executar cenário aprovado;
5. executar cenário recusado;
6. verificar Order no provider;
7. verificar webhook/reconsulta;
8. verificar estado financeiro interno;
9. depois abrir gate separado para 3DS.

## 10. Referências internas

- Issue #73 - Gate de live: sandbox real, dispositivos e proteção do main.
- PR #89 - deploy seguro do sandbox.
- PR #90 - correção do Supabase project ref.
- PR #91 - probe inicial de PIX/webhook via Payments API.
- PR #92 - preflight read-only da Payments API.
- PR #93 - migração para Orders API.
- PR #95 - alinhamento dos workflows à Orders API.
- PR #96 - gate PIX Orders API.
- PR #97 - primeiro gate de cartão.
- PR #98 - secure iframe fields.
- PR #99 - remoção de dependência dinâmica de parcelas.
- PR #100 - migração do harness para Card Payment Brick.
- PR #101 - diagnóstico do mount do Brick.
- Runs de cartão relevantes: 32613205538, 32613510566, 32613806231, 32614277261, 32614465013.

## 11. Regra final da auditoria

Integrações externas não devem ser consideradas engenharia comprovada apenas porque o código compila ou segue a documentação.

A evidência autoritativa precisa provar o contrato real com o fornecedor no ambiente apropriado para aquela camada.
