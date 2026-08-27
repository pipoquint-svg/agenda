# Agenda BlackSheep — pacote de preparação de produção

Data: 2026-08-27

Este documento prepara a implantação de produção sem executá-la. Não contém valores de secrets e não autoriza provider LIVE, cobrança real, OAuth de conta, domínio/cutover ou envio para destinatários reais.

## 1. Release Candidate

- SHA congelado: `812869914521144a75a07c3edf4b486ec93eaad6`.
- Staging autoritativo: `https://pipoquint-svg.github.io/agenda/`.
- Artifact: `staging-bundle-812869914521144a75a07c3edf4b486ec93eaad6`.
- Digest: `sha256:a425099b84dec19ad056b1ce0d3c99e5057a8136933507b392202a35c9ff78ba`.
- RC aprovado tecnicamente por Database Core, Web Core, Demand Capture e Staging HTTPS verdes.
- #291/#288 permanece pós-RC e não entra neste candidato.

## 2. Separação obrigatória de ambientes

Produção deve possuir projeto Supabase próprio. Não reutilizar projeto ref, URL, publishable key, service-role key, JWT/secret interno, chave de criptografia, tokens de providers nem credenciais de pagamento do sandbox.

### Frontend — valores públicos próprios de produção

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`
- chave pública Mercado Pago de produção, somente quando cobrança real for aprovada
- base/URL pública de produção conforme o mecanismo de hosting escolhido

### Edge / backend — secrets próprios de produção

Infraestrutura e segurança:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `INTEGRATION_INTERNAL_SECRET`

Google:
- `GOOGLE_INTEGRATION_ENABLED=false` no primeiro deploy
- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REDIRECT_URI`
- `GOOGLE_OAUTH_SUCCESS_URL`
- `GOOGLE_WEBHOOK_URL`
- `GOOGLE_ALLOWED_ACCOUNT_EMAIL`
- `GOOGLE_TEST_CALENDAR_PREFIX`
- `GOOGLE_TOKEN_ENCRYPTION_KEY` — obrigatoriamente novo e exclusivo de produção

Mercado Pago:
- `MERCADO_PAGO_ACCESS_TOKEN` — não preencher com credencial LIVE antes da aprovação específica
- `MERCADO_PAGO_WEBHOOK_SECRET`
- `MERCADO_PAGO_WEBHOOK_URL`

Kommo:
- `KOMMO_ACCESS_TOKEN` — não habilitar LIVE no provisionamento inicial

E-mail/notificações:
- `TRANSACTIONAL_EMAIL_ENABLED=false`
- `TRANSACTIONAL_EMAIL_WORKER_ENABLED=false`
- `NOTIFICATION_TEMPLATES_RUNTIME_ENABLED=false`
- `BIRTHDAY_EMAIL_DELIVERY_ENABLED=false`
- `TRANSACTIONAL_EMAIL_SCOPES`
- `RESEND_API_KEY`
- `EMAIL_FROM_BLACKSHEEP`
- `EMAIL_REPLY_TO_BLACKSHEEP`
- `EMAIL_FROM_SABRINA`
- `EMAIL_REPLY_TO_SABRINA`
- `EMAIL_TEST_RECIPIENT_ALLOWLIST`
- `ALLOW_REAL_EMAIL_RECIPIENTS=false`

## 3. Estado inicial seguro de produção

O primeiro deploy deve criar somente a infraestrutura da aplicação. Ao final desse deploy:

- Google permanece desligado;
- Kommo permanece desligado;
- cobrança real permanece desligada;
- envio transacional real permanece desligado;
- aniversário permanece inativo até configuração operacional explícita;
- nenhum cliente/cartão real é usado em smoke técnico;
- nenhuma fixture de sandbox é copiada para produção.

## 4. Sequência de provisionamento

### Fase A — ambiente

1. Criar ou identificar projeto Supabase exclusivo de produção.
2. Registrar project ref de produção fora do código e confirmar que é diferente de `jlyvlvmspfjwbcmhmhwz`.
3. Configurar região/plano apropriados.
4. Confirmar backup/PITR compatível com o plano antes de dados reais.
5. Criar secrets criptograficamente independentes do sandbox.

### Fase B — banco

1. Executar dry-run das migrations do RC.
2. Aplicar migrations somente a partir do repositório/SHA congelado.
3. Conferir tabela de migrations remotas contra o repositório.
4. Executar invariantes estruturais/read-only.
5. Rodar advisors e classificar qualquer achado novo antes de avançar.

### Fase C — Edge Functions

1. Configurar secrets mínimos de infraestrutura.
2. Manter todos os gates LIVE em `false`.
3. Deployar Edge Functions do mesmo RC.
4. Rodar smokes de autenticação/boundaries que não produzam efeitos externos.

### Fase D — web

1. Buildar o RC com `VITE_SUPABASE_URL` e publishable key de produção.
2. Não reutilizar chaves públicas do sandbox.
3. Publicar em HTTPS no domínio/hosting de produção aprovado.
4. Confirmar SHA servido.
5. Remover `noindex` somente no momento de cutover público aprovado; antes disso manter ambiente não indexável.

### Fase E — Auth/admin

1. Revisar Site URL e redirect URLs de produção.
2. Criar/bootstrap do primeiro owner por fluxo administrativo controlado.
3. Confirmar RBAC e acesso negado a usuário sem permissão.
4. Não executar OAuth Google como parte deste passo.

### Fase F — smoke sem efeitos externos

- leitura da página pública;
- leitura de catálogo/slots sem criar reserva real;
- tela de login/admin;
- health/read models;
- boundaries de Edge sem sessão;
- filas vazias;
- zero webhook/provider disparado.

## 5. Habilitação futura por provider

Providers são gates independentes e nunca devem ser ligados em lote.

### Google

Pré-condições: redirects corretos, chave de criptografia exclusiva, calendário/conta definidos. OAuth exige participação da usuária. Primeiro smoke deve ser controlado e reversível.

### Mercado Pago

Pré-condições: credenciais LIVE aprovadas, webhook de produção configurado, callback Orders reconciliado, teste controlado autorizado. Não usar cartão real antes desse gate.

### Kommo

Pré-condições: token/conta/pipeline confirmados e autorização explícita de LIVE. Habilitar somente depois de observar fail-closed com integração desligada.

### E-mail

Pré-condições: domínio/remetentes verificados, sink/allowlist testado, templates aprovados. `ALLOW_REAL_EMAIL_RECIPIENTS` fica `false` até autorização específica.

## 6. Dados

- Produção nasce sem clientes sintéticos de staging.
- Não copiar `integration_jobs`, audit logs de QA, Token Evidence, reservas sintéticas ou ciclos de aniversário do sandbox.
- Dados históricos reais só entram por migração/importação explicitamente planejada e auditável.
- Qualquer importação deve ser separada do deploy estrutural para permitir rollback e reconciliação.

## 7. Critérios GO / NO-GO

GO técnico somente se:
- projeto de produção identificado inequivocamente;
- backup/restore disponível/documentado;
- migrations reconciliadas;
- Edge e web no mesmo RC;
- smoke sem efeito externo verde;
- filas vazias;
- Auth/RBAC fail-closed;
- advisors sem bloqueador novo;
- rollback executável.

NO-GO imediato se:
- qualquer referência de sandbox aparecer em runtime de produção;
- secret for reutilizado entre ambientes;
- provider produzir efeito externo antes do gate;
- SHA publicado divergir do RC;
- houver drift de migrations;
- Auth/admin permitir acesso indevido;
- não houver estratégia de recuperação/rollback.

## 8. Rollback

- Web: retornar ao último artifact/SHA verde.
- Edge: redeploy do último SHA verde e desligar gates externos primeiro.
- Banco: preferir forward-fix; não usar `CASCADE` destrutivo.
- Provider: desligar imediatamente o gate da integração afetada antes de qualquer investigação longa.
- Domínio: manter capacidade de retornar ao frontend anterior enquanto o novo ambiente estabiliza.

## 9. O que ainda exige decisão/autorização antes do cutover

- projeto/plano Supabase de produção caso ainda não exista;
- domínio/hostname público final;
- credenciais LIVE do Mercado Pago;
- OAuth/conta Google e calendários reais;
- Kommo LIVE;
- provider/remetentes de e-mail e liberação de destinatários reais;
- momento explícito do cutover público.

Até esses gates serem atendidos, o estado correto é **produção preparada, não ativada**.
