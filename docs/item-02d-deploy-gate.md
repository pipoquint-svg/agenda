# Item 2D — rebuild por migrations como gate obrigatório de deploy (#372)

## Estado auditado antes da mudança

Após o Item 2C, o repositório possuía um `Database Core` forte e obrigatório operacionalmente nos PRs, mas não possuía workflow versionado de deploy para produção. O cutover continuava descrito em runbooks como uma sequência manual. Assim, o rebuild era evidência de qualidade, não uma dependência técnica do ato de promover migrations ou Edge Functions.

Esta etapa não altera Google Calendar, Mercado Pago, Kommo, serviços, políticas comerciais, RLS de produção nem corpos de funções. Ela altera somente o processo versionado de validação/deploy.

## Contrato introduzido

`Database Core` agora também aceita `workflow_call` e passa a ser o gate reutilizável canônico. Além do rebuild completo por migrations, pgTAP/regressões, concorrência e HTTP gate já existentes, ele valida em todo rebuild:

- overlay ACL atual do Item 2C;
- inventário RLS completo contra o baseline versionado do Item 2A-bis.

`.github/workflows/production-deploy.yml` é a entrada oficial de deploy de banco/backend. Ela é exclusivamente manual (`workflow_dispatch`) e exige:

1. execução a partir de `main`;
2. confirmação do SHA completo de 40 caracteres;
3. `expected_sha == github.sha`;
4. `Database Core` verde como job `needs` no mesmo workflow/SHA;
5. checkout novamente do mesmo `github.sha` antes da promoção;
6. ambiente GitHub `production` para acesso às credenciais de deploy.

O job de produção não executa se o rebuild estiver ausente, cancelado ou vermelho.

## Banco de produção e histórico legado de migrations

O histórico remoto anterior a esta etapa contém versões de aplicação que não correspondem sempre ao timestamp do nome do arquivo local, consequência do processo legado/manual de aplicação. Por isso o workflow de produção deliberadamente **não usa `--include-all`**. Também são proibidos `--include-seed` e `db reset --linked` em produção.

O fluxo de banco é:

1. `supabase link --project-ref sbexdggbwqvyhbkatucs`;
2. `supabase db push --linked --dry-run`;
3. somente se o dry-run for verde, `supabase db push --linked --yes`.

Novas migrations devem permanecer estritamente versionadas no repositório e seguir a ordem temporal posterior ao tail remoto atual. Qualquer divergência que faça o dry-run falhar é NO-GO; não usar `--include-all` para contornar o erro.

## Edge Functions

Edge Functions podem ser promovidas pelo mesmo workflow, após o mesmo rebuild e a mesma validação de SHA, usando `supabase functions deploy --project-ref sbexdggbwqvyhbkatucs`. O workflow não cria, substitui ou altera secrets de providers. Configuração externa continua fora de escopo.

## Credenciais de deploy

O workflow referencia apenas credenciais de infraestrutura do ambiente GitHub `production`:

- `SUPABASE_ACCESS_TOKEN`;
- `SUPABASE_DB_PASSWORD` quando houver deploy de banco.

Ausência dessas credenciais faz o deploy falhar fechado. Elas não devem ser colocadas no repositório. Nenhuma credencial Google, Mercado Pago ou Kommo é usada no rebuild.

## Provas fail-closed

`scripts/test-production-deploy-gate.sh` e `.github/workflows/item-02d-deploy-gate.yml` provam em ambiente descartável:

- o workflow de produção não possui trigger automático;
- o deploy depende explicitamente do `Database Core`;
- SHA/ref exatos são exigidos;
- seed, reset remoto e `--include-all` são proibidos;
- remover a migration 2C necessária faz o contrato de banco falhar;
- introduzir deliberadamente drift ACL faz o overlay canônico falhar;
- após restauração, ACL e RLS retornam ao estado versionado verde.

O próprio workflow 2D também chama o mesmo `Database Core` reutilizável usado por produção, evitando uma prova paralela diferente do gate real.

## Mudança manual/emergencial

DDL, GRANT/REVOKE, criação/alteração de função ou mudança de schema diretamente em produção não são caminho normal de deploy. Em incidente real, uma intervenção manual só pode ser tratada como emergência temporária e deve gerar imediatamente uma migration de reconciliação no repositório antes de qualquer próxima promoção. O rebuild e os inventários devem voltar a verde antes do deploy seguinte.

Não mascarar drift editando baseline para acomodar um estado remoto não explicado. Primeiro identificar a origem, versionar a reconciliação e provar o rebuild.

## Critério de saída

Item 2D só está concluído quando, no HEAD da PR:

- `Item 2D Mandatory Deploy Gate` verde;
- `Database Core` verde pelo caminho reutilizável;
- demais gates aplicáveis verdes;
- PR mergeada sem alterar produção;
- após merge, o workflow oficial de produção existe em `main` e mantém `needs: [validate-release, rebuild]` antes do job `deploy`.

Esta documentação substitui, para novas promoções, qualquer trecho de runbook antigo que descreva aplicação manual direta de migrations/Edge Functions como fluxo normal.
