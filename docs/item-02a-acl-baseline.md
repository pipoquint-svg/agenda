# Item 2A — baseline completa de ACL do schema `public`

## Escopo

A Fase 2A versiona a ACL inteira do schema `public`, sem alterar RLS e sem reinterpretar privilégios. A fonte de verdade é o mapa read-only de produção coletado em 2026-09-02 no projeto Agenda Produção (`sbexdggbwqvyhbkatucs`).

Cobertura obrigatória:

- todas as tabelas;
- todas as views/materialized views;
- todas as funções;
- todas as sequences;
- todos os owners, grantors e grantees presentes no mapa produtivo (`PUBLIC`, `anon`, `authenticated`, `postgres`, `service_role`).

A migration não usa `GRANT ALL`. Cada privilégio final é explícito e corresponde ao estado produtivo observado. Objetos Kommo são incluídos apenas porque fazem parte do baseline de ACL; nenhum endpoint, segredo, configuração, job ou integração Kommo é acionado ou alterado.

## Evidência antes da correção

O rebuild do `main` continha o mesmo universo de objetos de produção, mas não reproduzia a ACL produtiva.

| Classe | Produção — objetos | Produção — linhas ACL | Local antes — objetos | Local antes — linhas ACL |
|---|---:|---:|---:|---:|
| functions | 414 | 803 | 414 | 777 |
| sequences | 2 | 12 | 2 | 10 |
| tables | 105 | 1614 | 105 | 1337 |
| views | 8 | 128 | 8 | 104 |

Diferença inicial: 26 ACLs de funções, 2 de sequences, 277 de tabelas e 24 de views.

Hashes canônicos de produção usados pelo gate:

- functions: `9cb2b004d96277b79b86fcf8181caee861dbca7628cb3a32218ef765a06cf284`;
- sequences: `a22f76984f935d27010a77efbbe5e0a13a21a2b818cd959edaafc37067a172ea`;
- tables: `fba3298eb16529b3f223c6def1fe895194534a5883595608923a5ecd0a3c4df4`;
- views: `f09dedfa6c33eb98d6840f295c537ce4be013f4f6949c094d7b28ebc14e164be`.

O artefato do CI guarda o inventário local e o diff linha a linha antes e depois da migration.

## Correção da descrição do processo de geração

A versão inicial desta documentação descrevia a migration como totalmente gerada a partir do mapa de produção. Isso era impreciso.

O inventário e os padrões vieram do mapa read-only de produção, porém houve uma **etapa manual de transcrição/normalização em arrays de exceção**. Essa etapa introduziu o nome incorreto `touch_extra_schedule_version()` no lugar de `touch_service_extra_schedule_version()`.

Não houve truncamento automático do nome. O erro foi humano nessa etapa intermediária e foi corrigido.

Consequentemente, **o método de geração não é a prova de correção da Fase 2A**. A prova é mecânica e independente do método: após rebuild limpo, o CI compara identidade e **cada linha de ACL** contra o snapshot canônico de produção e exige diff zero, além dos hashes/resumos esperados.

## `anon` e `authenticated`

Em produção e no rebuild anterior à migration, `anon` e `authenticated` não possuem grants diretos em tables, views ou sequences do schema `public`.

O baseline produtivo contém `EXECUTE` explícito em RPCs específicas — 7 funções para `anon` e 8 para `authenticated`. A Fase 2A preserva esses privilégios sem ampliar nem reduzir a superfície pública.

O gate falha se qualquer grant direto em relation aparecer para `anon` ou `authenticated`.

## Estratégia da migration

A migration `20260902150000_reconcile_public_acl_baseline.sql` normaliza o rebuild para o baseline observado:

- relations: privilégios explícitos do owner `postgres` e de `service_role`, incluindo as exceções observadas em produção;
- sequences: privilégios conforme produção;
- functions: `EXECUTE` conforme o mapa produtivo, inclusive funções owner-only, funções com `PUBLIC` e RPCs públicas;
- nenhum `WITH GRANT OPTION`, pois produção possui zero ACLs grantable.

A migration não muda owner, RLS, política RLS, dados, configuração de serviços, Google Calendar, Mercado Pago ou Kommo.

## Expected failures autorizados — Item 2C

A paridade com produção revelou que `service_role` possui `EXECUTE` em cinco RPCs para as quais o próprio repositório possui seis assertions de hardening. A correção desses grants pertence ao **Item 2C — Hardening de EXECUTE do service_role (#371)**, que é bloqueador depois da 2B e antes do Item 3.

Enquanto o Item 2C estiver aberto, a Fase 2A aceita **somente** estas seis falhas, com nomes e quantidade exatos e sem modificar os arquivos de teste:

1. `service_role cannot bypass the audited policy wrapper`;
2. `legacy timing mutation is no longer directly executable by service role`;
3. `legacy duration configuration mutation is no longer directly executable by service role`;
4. `internal policy primitive is not directly executable by service role`;
5. `service_role cannot invoke maintenance purge`;
6. `application service_role cannot invoke five-year maintenance purge`.

O gate executa os quatro arquivos originais diretamente, confirma exatamente esses seis `not ok`, e falha se surgir uma sétima falha, se um nome mudar ou se um arquivo deixar de ter plano TAP. Em seguida, isola apenas esses quatro arquivos da rodada agregada e exige que todo o restante do pgTAP fique verde. Isso registra a divergência sem enfraquecer as assertions.

## Consulta read-only dos purges antes do Item 2C

Em produção, antes de qualquer mudança:

- `public.audit_purge_runs`: 0 linhas;
- `public.appointment_token_network_purge_runs`: 0 linhas;
- busca por `purge` em `public.audit_logs`: 0 registros;
- logs PostgreSQL/API disponíveis das últimas 24h: nenhuma chamada visível aos dois RPCs;
- `track_functions=none`.

As duas funções registram evidência antes do `DELETE` na mesma transação; portanto, não há evidência de purge bem-sucedido desde a criação das rotinas. A observabilidade atual não permite provar ausência de tentativas antigas que tenham falhado antes do commit, porque não há histórico de execução de função e os logs disponíveis são limitados.

## Achado separado — arquivo SQL indevidamente integrado ao pgTAP

`supabase/tests/20260902090500_external_physical_block_post_buffer_test.sql` não é um teste pgTAP. Ele contém quatro blocos `DO` com `RAISE EXCEPTION` e nenhum `plan()`/assertion TAP.

Os quatro checks cobrem exclusivamente o buffer de bloqueio físico externo:

1. preserva limite inferior e acrescenta +30 min no limite superior;
2. atualização apenas de metadata não empilha o buffer;
3. reconciliação do range bruto é idempotente;
4. alocação `PERSON` mantém range bruto.

Nenhum desses quatro checks é de segurança.

Histórico: arquivo criado em 2026-09-02 12:05:34 UTC e ajustado em 2026-09-02 12:07:49 UTC. O SQL **é executado** pelo PostgreSQL e um `RAISE EXCEPTION` falharia, porém o `pg_prove` o interpreta como TAP e reporta `No plan found`, produzindo semântica de harness incorreta e falsa impressão de cobertura pgTAP. Na Fase 2A ele passa a ser executado explicitamente via `psql -v ON_ERROR_STOP=1`; depois é retirado apenas da agregação pgTAP. A correção estrutural desse teste deve ser tratada separadamente do baseline de ACL.

## Critério de saída da Fase 2A

A Fase 2A só pode ser considerada concluída quando o CI do mesmo SHA comprovar:

1. baseline sem a migration diverge de produção;
2. rebuild limpo com a migration tem identidade exata do universo `public`;
3. diff de ACL **linha a linha = 0**;
4. hashes canônicos idênticos aos de produção para tables, views, functions e sequences;
5. zero grants diretos de relation para `anon` e `authenticated`;
6. migration idempotente;
7. arquivo SQL herdado executado diretamente e seus quatro checks verdes;
8. exatamente as seis falhas do Item 2C confirmadas e todo o restante do pgTAP verde;
9. suites de concorrência verdes;
10. action-token HTTP verde;
11. E2E local de locação/Pix verde;
12. worker Google local verde;
13. web/Playwright verdes.

O `before` deve falhar por drift de ACL; o `after` deve ficar sem `ACL_ROW_DIFF`, `IDENTITY_DIFF` ou `ACL_SUMMARY_DIFF`.

## Achado de processo — prevenir recorrência de drift

O pagamento Pix local expôs uma divergência sistêmica: produção tinha ACL operacional que um rebuild pelas migrations não reproduzia. A Fase 2A versiona o estado produtivo atual, mas isso não impede recorrência.

Foi criado o **Item 2D — Rebuild por migrations como gate obrigatório de deploy (#372)**. Ele deve impedir promoção de um SHA cujo banco não tenha sido reconstruído e testado integralmente a partir do histórico versionado em ambiente descartável. Sem esse gate, mudanças manuais podem recriar o drift.

## Sequência após 2A

- **2B:** RLS deny-by-default nas 10 tabelas críticas e matriz de acesso;
- **2C (#371):** hardening dos cinco `EXECUTE` de `service_role`, com inventário prévio de callers e migração de callers legítimos para wrappers auditados antes de qualquer revoke;
- **2D (#372):** rebuild por migrations como gate obrigatório de deploy;
- **Item 3:** somente depois de 2B, 2C e 2D concluídos.

Nenhuma mudança de RLS, grant produtivo, Google Calendar, Mercado Pago ou Kommo faz parte da Fase 2A.
