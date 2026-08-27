# Pré-produção — freeze, rollback e cutover seguro

Data: 2026-08-27

Este runbook documenta o fechamento técnico da Agenda BlackSheep antes de qualquer produção. Ele não autoriza produção, credenciais LIVE, OAuth Google, Kommo LIVE ou cobrança real.

## Estado candidato

- `main` observada antes deste documento: `251b809f043c2cb7ee9181b00ad577f5082f2872`.
- Artifact de staging correspondente: `staging-bundle-251b809f043c2cb7ee9181b00ad577f5082f2872`.
- Digest do artifact: `sha256:72f0a137d3ef8cb4fc5b1e135e635d315e4f148edb611cd7ee3f1d070bdd0a28`.
- Sandbox Supabase: `jlyvlvmspfjwbcmhmhwz`.
- O SHA acima é apenas evidência pré-RC. O RC final só pode ser declarado após o #236 fechar com HTTPS autoritativo servindo o mesmo SHA do bundle.

## Gates antes de declarar RC

1. Database Core verde no SHA candidato.
2. Web Core verde no SHA candidato ou em SHA com conteúdo `web/` byte-equivalente, seguido de execução explícita no RC quando possível.
3. Demand Capture verde no SHA candidato.
4. Sandbox Core Deploy verde e migrations reconciliadas.
5. Filas sem `PENDING`/`PROCESSING` envelhecidos; todo `FAILED` classificado.
6. Security/Performance Advisors reexecutados e classificados.
7. Bundle com `noindex`, fallback SPA e `release-sha.txt`.
8. Staging HTTPS autoritativo servindo o SHA candidato.
9. Browser smoke público e administrativo contra o HTTPS autoritativo.
10. Nenhuma integração LIVE habilitada por efeito do freeze.

## Rollback de aplicação

- Reverter primeiro o frontend para o último SHA conhecido verde.
- Edge Functions devem ser redeployadas a partir do mesmo SHA/commit conhecido verde; não editar manualmente função remota como correção permanente.
- Se a falha for isolada a uma função, desabilitar o consumidor/feature flag aplicável antes de qualquer mudança de banco.
- Providers externos permanecem fail-closed e devem ser mantidos desligados durante rollback.

## Rollback de banco

- Não usar `CASCADE` destrutivo como estratégia de rollback.
- Preferir migrations forward-fix para schema expand-only.
- Não remover coluna/tabela/constraint que possa conter evidência histórica sem uma migration explícita de compatibilidade e prova de ausência de uso.
- Constraints adicionadas em duas fases (`NOT VALID` -> reconciliação -> `VALIDATE`) não devem ser revertidas apagando dados históricos.
- Antes de qualquer mudança destrutiva futura, registrar backup/PITR disponível no projeto de produção e ensaiar restauração em ambiente isolado.

## Critérios objetivos para abortar lançamento

Abortar ou não iniciar cutover se ocorrer qualquer um dos seguintes:

- staging HTTPS não corresponde ao SHA declarado;
- qualquer gate obrigatório vermelho no SHA candidato;
- migrations locais/remotas divergentes;
- job operacional `PENDING`/`PROCESSING` envelhecido sem causa explicada;
- falha de autenticação/autoridade permitindo acesso administrativo indevido;
- cobrança, mensagem, Google ou Kommo produzindo efeito externo não autorizado;
- advisor novo classificado como bloqueador;
- ausência de mecanismo de rollback conhecido para a mudança candidata.

## Ordem futura de cutover

Somente após autorização explícita:

1. confirmar backup/restore e janela de rollback;
2. aplicar banco;
3. redeployar Edge Functions;
4. publicar web;
5. validar domínio/redirects;
6. executar smoke sem efeitos externos;
7. habilitar integrações uma por uma, cada qual com seu gate próprio;
8. monitorar primeira hora e primeiro dia por filas, logs, webhooks e health checks.

## Integrações deliberadamente fora do freeze técnico

- Google OAuth real: exige participação da usuária.
- Kommo LIVE: permanece desabilitado até autorização explícita.
- Mercado Pago produção/cobrança real: permanece proibido até autorização explícita.
- credenciais/domínio/cutover de produção: não criar nem alterar nesta fase.

## Bloqueio atual

O #236 continua bloqueado por infraestrutura de hosting. O GitHub Pages falha em `Configure Pages` com `Resource not accessible by integration`; o build e o artifact SHA-linked são preservados antes desse passo. O #289 isola a ação de infraestrutura necessária para disponibilizar um hosting HTTPS derivado diretamente do GitHub/SHA.
