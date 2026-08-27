# Pré-produção — freeze, rollback e cutover seguro

Data: 2026-08-27

Este runbook documenta o fechamento técnico da Agenda BlackSheep e a preparação para produção. Ele **não autoriza** criação/alteração de credenciais LIVE, OAuth de conta Google, Kommo LIVE, cobrança real nem cutover de produção.

## Release Candidate técnico congelado

- RC: `812869914521144a75a07c3edf4b486ec93eaad6`.
- Staging autoritativo: `https://pipoquint-svg.github.io/agenda/`.
- Artifact preservado: `staging-bundle-812869914521144a75a07c3edf4b486ec93eaad6`.
- Digest: `sha256:a425099b84dec19ad056b1ce0d3c99e5057a8136933507b392202a35c9ff78ba`.
- Sandbox Supabase: `jlyvlvmspfjwbcmhmhwz`.
- `release-sha.txt` via HTTPS e browser smoke autoritativo provam o mesmo SHA do RC.
- #236 e #289 foram concluídos após habilitação do GitHub Pages e publicação GitHub-first.
- Novas features ficam fora deste RC. O #291/#288 está classificado como pós-RC e não bloqueador.

## Gates do RC — concluídos

1. Database Core verde no SHA `812869...`, incluindo rebuild integral por migrations, pgTAP, concorrência, rate-limit e action-token HTTP.
2. Web Core verde no mesmo SHA.
3. Demand Capture verde no mesmo SHA.
4. Staging HTTPS verde no mesmo SHA.
5. Browser smoke HTTPS autoritativo verde nas superfícies públicas e administrativas cobertas.
6. `noindex,nofollow,noarchive`, fallback SPA e `release-sha.txt` confirmados no bundle publicado.
7. Sandbox sem `PENDING`/`PROCESSING`; `FAILED` existentes classificados como fixtures sintéticas pré-LIVE.
8. Zero ciclos de aniversário executados; configurações permanecem inativas.
9. Zero serviços ativos sem `service_change_policies`.
10. Security/Performance Advisors reexecutados; sem novo bloqueador técnico do RC.
11. Nenhuma integração LIVE foi habilitada por efeito do freeze.

## Estado do sandbox no freeze

- `integration_jobs`: 12 `SUCCEEDED`, 6 `FAILED` sintéticos/classificados, 0 `PENDING`, 0 `PROCESSING`.
- `birthday_automation_cycles`: 0.
- Aniversário `SABRINA`: inativo.
- Aniversário `BLACKSHEEP`: inativo.
- Serviços ativos sem política: 0.

Os dados e credenciais do sandbox **não são fonte de configuração de produção**. Produção deve usar projeto, chaves e secrets próprios.

## Rollback de aplicação

- Reverter primeiro o frontend para o último SHA conhecido verde.
- Edge Functions devem ser redeployadas a partir do mesmo SHA conhecido verde; não editar função remota manualmente como correção permanente.
- Se a falha for isolada a uma integração, desligar o gate/consumer aplicável antes de qualquer mudança de banco.
- Providers externos permanecem fail-closed durante rollback.

## Rollback de banco

- Não usar `CASCADE` destrutivo como estratégia de rollback.
- Preferir migrations forward-fix para schema expand-only.
- Não remover coluna/tabela/constraint que possa conter evidência histórica sem migration explícita de compatibilidade e prova de ausência de uso.
- Constraints adicionadas em duas fases (`NOT VALID` -> reconciliação -> `VALIDATE`) não devem ser revertidas apagando dados históricos.
- Antes de qualquer mudança destrutiva futura, confirmar backup/PITR no projeto de produção e ensaiar restauração em ambiente isolado.

## Critérios objetivos para abortar lançamento

Abortar ou não iniciar cutover se ocorrer qualquer um dos seguintes:

- SHA publicado divergir do RC aprovado;
- qualquer gate obrigatório ficar vermelho no SHA candidato;
- migrations locais/remotas divergirem;
- fila operacional acumular `PENDING`/`PROCESSING` sem causa explicada;
- autenticação/autoridade permitir acesso administrativo indevido;
- cobrança, mensagem, Google ou Kommo produzir efeito externo antes do respectivo gate;
- advisor novo for classificado como bloqueador;
- ausência de rollback conhecido para a mudança candidata;
- produção tiver recebido secret/chave reutilizado do sandbox por conveniência.

## Ordem futura de cutover

Somente após os gates explícitos de produção:

1. confirmar projeto de produção, backup/PITR e janela de rollback;
2. aplicar migrations do RC no projeto de produção;
3. deployar Edge Functions do RC com integrações LIVE ainda desligadas;
4. configurar secrets de produção próprios, mantendo gates LIVE em `false`;
5. publicar o frontend com URL/chaves públicas do projeto de produção;
6. validar domínio, HTTPS, redirects e Auth URLs;
7. executar smoke sem efeitos externos;
8. bootstrap/controlar acesso administrativo de produção;
9. habilitar providers um por vez, cada qual com aprovação e smoke próprios;
10. monitorar primeira hora e primeiro dia por filas, logs, webhooks e health checks.

## Integrações deliberadamente fora do freeze técnico

- Google OAuth real: exige participação da usuária para autenticação da conta.
- Kommo LIVE: permanece desabilitado até autorização explícita.
- Mercado Pago produção/cobrança real: permanece desligado até autorização explícita.
- E-mail para destinatários reais: permanece bloqueado até gate explícito.
- Domínio/cutover de produção: somente depois de projeto e configuração de produção aprovados.

## Bloqueio atual para sair de “preparação” e entrar em “provisionamento”

O RC técnico está pronto. O próximo gate é **provisionar/identificar o ambiente real de produção e seus secrets próprios**, sem reutilizar sandbox. Essa etapa pode gerar custo e criar infraestrutura persistente; por isso deve permanecer separada do preparo documental e do freeze. Nenhuma credencial LIVE ou integração externa deve ser ligada durante o provisionamento inicial.
