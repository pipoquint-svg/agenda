# Auditoria da integração Mercado Pago no sandbox

Data de consolidação: 23/08/2026

Status: documento de auditoria. Não equivale a `SANDBOX TESTED` completo, `STAGING TESTED` ou `LIVE APPROVED`.

Escopo: reconstruir falhas, decisões, correções, evidências e aprendizados desde o início da implantação real do Mercado Pago na Agenda BlackSheep.

## 1. Resumo executivo

A integração não falhou como um todo. O backend do Mercado Pago via Orders API já possui evidências positivas no sandbox para credencial, preflight read-only, deploy remoto, webhook Order, HMAC, criação de PIX, consulta da Order e idempotência do provedor.

O principal gate ainda aberto é cartão browser-side, seguido de 3DS e jornada financeira end-to-end da Agenda.

O episódio revelou **duas classes independentes de erro metodológico**, e ambas passam a ser conclusão central desta auditoria:

1. **Contrato do fornecedor não provado antes de codificar.** Isso explica principalmente os erros ligados a Payments API versus Orders API, parâmetros obrigatórios e interpretação de respostas do provedor.
2. **Harness de teste não provado como representante de produção.** Isso explica principalmente a sequência do cartão. O Card Payment Brick foi exercitado em `http://127.0.0.1:<porta>` dentro de runner headless até que o run 32614465013 demonstrou falhas de inicialização associadas ao contexto do ambiente, com CORS, ORB, 403/404 e controller nunca criado.

A segunda classe consumiu a maior parte das tentativas de cartão e tende a reaparecer em OAuth Google, 3DS, redirects, cookies, popups, iframes e outros componentes dependentes de navegador/origem HTTPS.

**Conclusão operacional:** não executar novo patch incremental no Card Gate headless. O próximo passo é provisionar um **staging HTTPS real da Agenda**, usar nele o frontend real conectado ao backend sandbox e executar cartão, 3DS, Google OAuth e jornadas em dispositivo nesse ambiente.

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

Limitação: reduziu risco, mas ainda validava a família de API que posteriormente deixou de ser o alvo.

Correção estrutural: após a migração para Orders, o preflight passou para `GET /v1/orders`.

Classificação: mensagem potencialmente enganosa do fornecedor + diagnóstico parcial nosso.

Aprendizado: não tratar a mensagem textual da API como causa raiz antes de validar endpoint, produto, escopo e integração correta.

### 2.3 Reference ID incorreto do Supabase sandbox

O workflow inicial usava um Reference ID transcrito com um caractere ausente e, por consequência, URL de webhook incorreta.

Correção: PR #90 ajustou o Reference ID e a URL pública da Edge Function.

Classificação: erro de transcrição/configuração.

Aprendizado: IDs de infraestrutura devem ser validados programaticamente; não confiar em transcrição manual.

### 2.4 Automação do deploy antes do contrato estabilizar

O PR #89 criou corretamente um deploy seguro com confirmação `SANDBOX`, segregação de ambiente, charges/dados reais bloqueados, secrets fora do código, migrations e Edge Functions.

Porém o workflow ainda estava acoplado ao modelo anterior de API/evento.

Correção: PR #95 alinhou o deploy à Orders API, evento `order`, preflight correto e secrets definitivos.

Classificação: sequenciamento inadequado.

Aprendizado: primeiro provar o contrato mínimo do fornecedor; depois automatizar profundamente o deploy.

### 2.5 Parâmetros obrigatórios da busca de Orders

A busca read-only em Orders exigia filtros temporais obrigatórios.

Correção: PR #95 passou a enviar `begin_date`, `end_date` e paginação mínima.

Classificação: contrato de API não capturado na primeira tentativa.

Aprendizado: toda integração externa deve começar por uma requisição mínima reproduzível com método, endpoint, headers, parâmetros obrigatórios e resposta real registrados.

### 2.6 PIX via Orders API

O PR #96 criou gate isolado para PIX no sandbox e validou:

- Order fictícia de R$ 50,00;
- uma única transação `pix / bank_transfer`;
- estado inicial `action_required / waiting_transfer`;
- QR/ticket retornado sem ser impresso;
- `GET /v1/orders/{id}`;
- replay da mesma idempotency key devolvendo a mesma Order.

Resultado: provider-level PIX funcional no sandbox.

Classificação: evidência positiva.

Aprendizado: gates pequenos e isolados produzem diagnóstico melhor do que tentar provar a jornada inteira de uma vez.

## 3. Sequência específica do cartão

### 3.1 Gate inicial misturava cartão comum e 3DS

O PR #97 introduziu Card Gate headless com MercadoPago.js/CardForm e cenários que misturavam conceitos de aprovação/recusa com autenticação.

Correções posteriores:

- cenários comuns passaram para `APRO` e `OTHE`;
- `transaction_security` saiu do gate comum;
- 3DS foi separado como gate posterior.

Classificação: desenho de teste inadequado.

### 3.2 Run 32613205538: input oculto de expiração

Causa: Playwright varria inputs genericamente e confundiu campo visível com input interno/oculto.

Correção: PR #98 passou a preencher secure fields por containers/iframes explícitos.

Nenhuma Order criada.

### 3.3 Run 32613510566: issuer/parcelas desnecessários

Causa: o harness aguardava selects dinâmicos de issuer e installments que não eram necessários para validar compra sandbox em uma parcela.

Correção: PR #99 removeu a dependência e fixou `installments=1` apenas no gate sandbox.

Nenhuma prova end-to-end obtida.

### 3.4 Run 32613806231: CardForm não entregou token no submit headless

O formulário montava e era preenchido, mas o submit não produziu token.

Correção: PR #100 substituiu CardForm pelo Card Payment Brick, corrigiu `APRO`/`OTHE`, separou 3DS e adicionou diagnóstico sanitizado.

**Ponto de processo:** após esta terceira falha, o ambiente deveria ter sido revalidado antes de novo patch.

### 3.5 Run 32614277261: Brick não sinalizou `onReady`

Timeout de 45s antes de o Brick ficar pronto; nenhuma Order criada.

Correção: PR #101 simplificou inicialização e adicionou diagnóstico de console, page errors, requests falhos e inventário de campos.

A hipótese ainda era que o Brick deveria funcionar no runner; essa hipótese não estava provada.

### 3.6 Run 32614465013: ambiente headless inadequado identificado

O diagnóstico mostrou:

- `MercadoPago` carregado;
- `controllerCreated=false`;
- `ready=false`;
- `Bricks component initialization failed`;
- requests auxiliares com 404;
- chamadas bloqueadas por CORS;
- requests bloqueados por ORB;
- resposta 403 em recurso auxiliar;
- nenhum campo do Brick renderizado.

Conclusão: nessa execução, o problema não era cartão, CPF, cenário `APRO`, JSON da Order, Access Token ou seletor. O componente não conseguiu inicializar adequadamente no microservidor localhost do GitHub Actions.

Classificação: estratégia de ambiente de teste inadequada.

Decisão: descontinuar o Card Gate headless como prova autoritativa de integração browser-side.

## 4. O que estava verde antes da prova real

Este ponto passa a ser parte central da auditoria.

O workflow `Database Core` executa testes locais de helpers para Google, WhatsApp e Mercado Pago. Eles são válidos, mas **não tocam os fornecedores reais**.

### Google

`supabase/functions/_shared/google_test.ts` prova, entre outros:

- criptografia/decriptografia local do refresh token;
- construção da URL OAuth;
- scopes solicitados;
- normalização de eventos;
- hashing.

Não prova:

- consent screen real;
- redirect URI real;
- emissão/renovação real de token;
- Calendar API real;
- watch/webhook real;
- comportamento do app em `Testing` versus publicado.

### WhatsApp

`supabase/functions/_shared/whatsapp_test.ts` prova:

- normalização de recipient;
- construção de URL de retomada;
- formato do payload de template.

Não prova:

- token Meta válido;
- número/recipient de teste;
- envio real;
- template aprovado;
- webhook/challenge;
- status de entrega.

### Mercado Pago

`supabase/functions/_shared/mercado-pago_test.ts` prova helpers locais como HMAC, normalização de status, sanitização e validação de dados tokenizados.

Não provava, por si só:

- endpoint/provider correto;
- tokenização real;
- Brick real;
- cartão aprovado/recusado;
- 3DS.

### Regra decorrente

CI verde precisa declarar seu **escopo de evidência**. Nomes como “Google tests” ou “Mercado Pago tests” não podem ser interpretados como integração aprovada quando são apenas contratos internos.

Classificação de evidência recomendada para cada suíte:

- `LOCAL_CONTRACT`;
- `DATABASE_CONTRACT`;
- `PROVIDER_SANDBOX`;
- `STAGING_BROWSER`;
- `END_TO_END`;
- `LIVE`.

## 5. pgTAP e a divergência de plano

Durante a migração Orders foram encontrados:

- `006_change_policy.test.sql`: plano de 20 para 19 asserts executados;
- fixture de `046_customer_balance_and_settlement`: UUID OPERATION incorreto na branch em propagação.

Nuance importante: o workflow `Database Core` atual executa `supabase test db`. O pgTAP verifica a consistência entre o plano e a quantidade efetivamente executada. Portanto, **a divergência simples 20 versus 19 foi detectada pelo CI; não é correto descrevê-la como um teste que permaneceu verde silenciosamente naquele gate**.

O aprendizado ainda é relevante por dois motivos:

1. um gate só protege arquivos que realmente executa;
2. plano correto não prova cobertura semântica correta. Um teste pode executar N asserts e ainda validar a suposição errada.

Ação permanente:

- preservar `supabase test db` como gate obrigatório;
- antes de reescrever política financeira, confirmar que todos os arquivos de teste relevantes continuam descobertos pelo runner;
- revisar semanticamente os testes de política, saldo e liquidação, não apenas contagem de asserts.

## 6. Estados de evidência revisados

Os quatro estados anteriores eram insuficientes. A partir desta auditoria, integrações externas usam cinco estados mínimos:

1. `IMPLEMENTED` — código existe.
2. `CI PASS` — contratos locais/banco/build aprovados.
3. `SANDBOX TESTED` — fornecedor real de teste foi tocado nas camadas aplicáveis de API/webhook.
4. `STAGING TESTED` — frontend real em origem HTTPS representativa foi provado, incluindo SDK/OAuth/redirect/cookies/iframe/browser e, quando aplicável, jornada E2E com dados sintéticos.
5. `LIVE APPROVED` — produção explicitamente autorizada e smoke test controlado concluído.

Cada estado pode ser `NO`, `PARTIAL` ou `YES`, mas `PARTIAL` deve listar exatamente quais capacidades foram provadas.

### Estado atual do Mercado Pago

- `IMPLEMENTED`: YES para a arquitetura atual; jornadas finais ainda pendentes.
- `CI PASS`: YES para as frentes consolidadas.
- `SANDBOX TESTED`: PARTIAL — Orders API, PIX, webhook e HMAC provados; cartão/3DS não.
- `STAGING TESTED`: NO — staging HTTPS real ainda não provisionado/testado.
- `LIVE APPROVED`: NO.

## 7. Staging HTTPS é agora dependência crítica

O ambiente de staging HTTPS não existe como superfície comprovada da Agenda e passa a ser bloqueador explícito do Gate #73.

Ele destrava simultaneamente:

- cartão Mercado Pago;
- 3DS;
- OAuth Google com redirect URI real;
- jornada end-to-end em navegador;
- iPhone Safari/Android Chrome;
- cookies, CORS, popups, redirects e iframes em origem representativa.

Requisitos mínimos do staging:

- URL HTTPS estável;
- frontend real da Agenda;
- backend e banco sandbox;
- secrets exclusivamente de teste;
- dados sintéticos;
- robots/noindex quando público;
- nenhum charge, recipient ou dado de cliente real;
- capacidade de registrar SHA/deploy e evidências.

Não iniciar nova tentativa de cartão ou OAuth real antes desse ambiente existir.

## 8. Failure Budget para integração externa

Após **duas falhas consecutivas no mesmo gate externo**:

1. parar patches incrementais;
2. classificar a falha: código, contrato, credencial, ambiente ou fornecedor;
3. reabrir a documentação canônica;
4. provar que o harness representa o ambiente real;
5. verificar se o teste está na camada correta;
6. executar spike alternativo mínimo;
7. somente então alterar código novamente.

A regra vale para Mercado Pago, Google, WhatsApp e qualquer integração externa.

## 9. Protocolo por camadas

Fluxo obrigatório:

`Source of Truth -> Spike -> Provider Sandbox -> Staging HTTPS -> Jornada E2E -> Live`.

### Layer A — contrato local

Unitários, typecheck, parsing, payload e idempotência interna.

### Layer B — banco

Constraints, RLS, concorrência e state machine.

### Layer C — provider API

Credencial real de teste, endpoint real, request mínima e resposta real.

### Layer D — webhook/callback

Evento real ou simulador oficial, assinatura, replay, mismatch e idempotência.

### Layer E — browser staging

Domínio HTTPS real, SDK/OAuth/Brick, redirects, cookies, CORS, popup/iframe e mobile.

### Layer F — jornada completa

Entidade sintética interna, ação do usuário, fornecedor, retorno/webhook, estado interno final e compensação/erro.

Uma layer não aprova automaticamente a seguinte.

## 10. Aplicação imediata a Google e WhatsApp

### Google Calendar

Não considerar o Google “testado” pelo fato de helpers, migrations e Edge Functions passarem CI.

Antes de integrar operacionalmente:

1. staging HTTPS;
2. projeto e consent screen;
3. Client ID/segredo de teste;
4. redirect URI do staging;
5. usuário e calendário exclusivamente de teste;
6. OAuth real em navegador;
7. verificar estado de publicação do app;
8. se `Testing`, não aceitar refresh token de 7 dias como solução operacional;
9. leitura/criação/alteração reais;
10. watch/webhook;
11. sync incremental/full, drift/repair e reconexão.

### WhatsApp

Antes de automações completas:

1. app/número de teste;
2. recipient allowlist;
3. token real de teste;
4. envio mínimo;
5. template real aplicável;
6. webhook/challenge;
7. assinatura/status;
8. retry/idempotência;
9. só então fluxo operacional da Agenda.

## 11. Custo observável do episódio

GitHub permite registrar uma **janela de tempo observável**, não horas humanas exatas.

Entre a criação do PR #87, em 23/08/2026 00:26 UTC, e a conclusão do run de cartão 32614465013, em 03:06 UTC, transcorreram aproximadamente **2h40 de janela técnica observável**.

Nesse intervalo aparecem PRs #87 a #101 ligados direta ou indiretamente ao hardening/implantação do Mercado Pago, incluindo PRs funcionais, correções e PRs temporários de CI. Só no cartão há pelo menos cinco runs de falha documentados:

- 32613205538;
- 32613510566;
- 32613806231;
- 32614277261;
- 32614465013.

Não interpretar 2h40 como esforço humano líquido. É uma medida de wall-clock mínima observável para justificar a mudança de processo e permitir comparação futura.

Para integrações futuras, registrar:

- início do spike;
- número de runs;
- número de patches/PRs;
- falhas por categoria;
- momento em que Failure Budget foi acionado;
- momento em que o estado avançou.

## 12. Próximas ações, em ordem

1. Provisionar staging HTTPS real da Agenda.
2. Atualizar Gate #73 para tornar staging um bloqueador próprio.
3. Não executar novo Card Gate headless como evidência autoritativa.
4. Testar cartão aprovado e recusado no frontend real do staging.
5. Testar 3DS em gate separado.
6. Provar OAuth Google no mesmo staging antes de aprofundar sync/watch.
7. Provar WhatsApp com recipient allowlist e provider real de teste.
8. Manter inventário explícito de quais testes são apenas `LOCAL_CONTRACT` versus fornecedor real.

## 13. Referências internas

- Issue #73 — Gate de live: sandbox real, dispositivos e proteção do main.
- PR #89 — deploy seguro do sandbox.
- PR #90 — correção do Supabase project ref.
- PR #91 — probe inicial via Payments API.
- PR #92 — preflight read-only da Payments API.
- PR #93 — migração para Orders API.
- PR #95 — alinhamento dos workflows à Orders API.
- PR #96 — gate PIX Orders API.
- PR #97 — primeiro gate de cartão.
- PR #98 — secure iframe fields.
- PR #99 — remoção de dependência dinâmica de parcelas.
- PR #100 — migração para Card Payment Brick.
- PR #101 — diagnóstico do mount do Brick.

## 14. Regra final da auditoria

Integrações externas exigem duas provas antes de serem consideradas confiáveis:

> **provar o contrato real com o fornecedor e provar que o ambiente/harness de teste representa a camada que se pretende validar.**

Código que compila, teste que fica verde ou documentação que parece correta não substituem nenhuma das duas provas.
