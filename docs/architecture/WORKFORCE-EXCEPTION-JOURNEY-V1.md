# Jornada por Exceção — V1 (Workforce)

Status: **baseline aprovada (S0)**. Nenhuma funcionalidade operacional está habilitada nesta slice.
Decisão arquitetural: [ADR-017](ADR-017-workforce-exception-journey.md).

## 1. Objetivo

Controlar a jornada de funcionários da BlackSheep **por exceção**: na ausência de registro, considera-se cumprida a jornada habitual. A funcionária registra apenas o que foge do habitual (trabalho antes/depois do horário, fim de semana, feriado, atraso, saída antecipada, ausência). O owner revisa, classifica e fecha a competência mensal. Depois do fechamento, um relatório é enviado à contadora.

Isto **não** é ponto eletrônico (Portaria MTP 671/2021 não é o alvo) e **não** calcula folha.

## 2. Onde o módulo vive

| Camada | Repositório | Conteúdo |
| --- | --- | --- |
| Banco, regras, RPCs, Edge Functions, e-mail, worker | `pipoquint-svg/agenda` | `supabase/migrations`, `supabase/functions`, `supabase/tests/database` |
| Interface (Minha Jornada, Gestão → Equipe → Jornada, PDF) | `pipoquint-svg/black-sheep` | `src/components/gestao`, `src/pages` |

Os dois repositórios operam o mesmo projeto Supabase (`sbexdggbwqvyhbkatucs`). O BlackSheep não tem migrations próprias e não pode ganhar nenhuma: criar migrations ali bifurcaria o histórico do banco de produção.

### Fluxo de integração

- Cada slice gera um PR por repositório tocado. O PR do backend é mergeado antes do PR da interface.
- Os PRs entram em `workforce-v1`, em cada repositório, e **nunca** em `main` durante S0–S8.
- Motivo: `production-deploy.yml` aplica todas as migrations pendentes do `main`, e workflows `schedule:` no branch padrão ficam ativos imediatamente. Se as slices entrassem em `main`, qualquer hotfix posterior levaria o schema de workforce para produção.
- `workforce-v1` só é mergeado em `main`, e depois publicado, quando S0–S8 estiverem concluídas e houver autorização explícita.
- S0 inclui `workforce-v1` nos gatilhos `pull_request` dos gates centrais (`db-core`, `item-02a-bis-rls-baseline`, `item-03-edge-auth-contract`, `item-16-pgtap-plan`, `invoice-checkout-regression`, `demand-capture`, `preprod-consolidated-audit`, `web-core`). Assim, todo PR de slice passa pelo replay completo das migrations, pelos contratos de ACL/RLS e pela suíte pgTAP. `db-core` também roda em `push` para `workforce-v1`.

## 3. Auditoria da Agenda (estado em 2026-10-08, `main` = `a85c4e1`)

| Área | Achado | Consequência para o módulo |
| --- | --- | --- |
| Auth | Supabase Auth. Edge Functions validam o JWT com `adminClient().auth.getUser(jwt)` e resolvem `public.admin_users` por `service_admin_resolve_auth_user` (`_shared/supabase.ts`). | Sem auth paralela. A funcionária é um `admin_user` existente (login da Gestão). |
| Papéis | `admin_users.role ∈ {OWNER, ADMIN, OPERATION, FINANCE}`. Permissões por `service_admin_has_permission`; OWNER e ADMIN recebem todas por padrão. | Ações administrativas de jornada exigem **role OWNER** com membership OWNER ativa no tenant. ADMIN, OPERATION e FINANCE não herdam acesso. |
| Tenant | `public.tenants`, `tenant_members (OWNER, ADMIN)`, tenant canônico `blacksheep` (`8fba3c57-…`). Tabelas de domínio antigas ainda não têm escopo de tenant. | Todas as tabelas de workforce têm `tenant_id` obrigatório desde a criação. |
| Fronteira de API | Edge Functions com `service_role` chamam RPCs `public.service_*` `SECURITY DEFINER`, com `EXECUTE` só para `service_role`. O browser nunca escreve em tabela. | Mesmo padrão: `public.service_workforce_*`, chamadas só pelas Edge Functions do módulo. |
| Schemas expostos | PostgREST expõe somente `public` e `graphql_public` (`supabase/config.toml`). | As tabelas ficam no schema `workforce`, que não é exposto, sem grants para `anon`/`authenticated` e com RLS habilitada e forçada, sem policies (deny-all). |
| Gates de ACL/RLS | `tests/acl-parity/item02c_acl_overlay.sql` fixa o número exato de funções em `public` (hoje 473, das quais 407 executáveis por `service_role`). `scripts/rls-inventory.sql` inventaria as tabelas de `public`. | Cada slice que cria RPC pública atualiza essas contagens com comentário justificativo. Tabelas em `workforce` não alteram o inventário RLS de `public`, mas recebem testes próprios. |
| Migrations | 361 arquivos, forward-only, `YYYYMMDDHHMMSS_slug.sql`. O replay greenfield (`supabase db reset`) roda no `db-core`. | Uma migration canônica por slice. Nada de cadeia experimental. |
| Testes de banco | pgTAP em `supabase/tests/database/NNN_*.test.sql` (último: `165`). `scripts/test-database-core-gates.sh` roda `supabase test db` sem quarentena. | Os testes do módulo usam a faixa `170_workforce_*` em diante. |
| Edge auth | `supabase/functions/auth-contract.json` + `scripts/edge-auth-contract.py` definem o allowlist de deploy e o contrato de auth. | Cada Edge Function nova é registrada no contrato. |
| E-mail | Resend como provedor único (ADR-016), só via `_shared/email-provider.ts`. Há gates de plataforma de notificação no `db-core`. | S8 reutiliza `sendEmailWithProvider()`. Nenhum provedor novo. |
| Cron/jobs | Workflows `schedule:` do GitHub chamam Edge Functions com token OIDC (`_shared/github-oidc.ts`). Exemplos: `birthday-automation-schedule`, `integration-worker-schedule`. Também existe `pg_cron` pontual. | O dispatcher de S8 segue o padrão OIDC. A ativação do schedule fica separada e só vale no `main`. |
| Deploy | `production-deploy.yml` é manual (`workflow_dispatch`), com SHA exato e Database Core reutilizado. O frontend é publicado pelo Lovable. | Nenhuma slice publica produção. |
| Frontend | O BlackSheep chama a Agenda por `src/integrations/agenda/client.ts` e `src/lib/agendaAdminApi.ts`. A Gestão fica em `src/components/gestao` (inclui `TeamModule`/`TeamPeopleModule`). | Jornada entra como sub-área de Equipe. Minha Jornada é uma superfície própria para a funcionária. |

## 4. Modelo de domínio

`tenant` (organização da Agenda) ≠ `employer` (empregadora jurídica) ≠ `employee`.

```
public.tenants ─┬─ workforce.employers ──┬─ workforce.payroll_settings (1:1)
                │                         ├─ workforce.holidays (territoriais)
                │                         └─ workforce.employees ── admin_users (login existente)
                │                                    ├─ workforce.employment_schedules (vigência)
                │                                    │      └─ workforce.employment_schedule_days
                │                                    ├─ workforce.work_exceptions ── work_exception_segments
                │                                    │      ├─ work_exception_classifications (append-only)
                │                                    │      ├─ work_exception_corrections
                │                                    │      └─ work_exception_acknowledgements
                │                                    ├─ workforce.compliance_alerts
                │                                    └─ workforce.work_periods ── work_period_closures (versões)
                │                                                     ├─ work_period_reports
                │                                                     └─ work_report_deliveries
                └─ workforce.audit_log / workforce.command_receipts
```

Dados iniciais configuráveis, nunca regra de produto:

- Empregadora: razão social **Pierri Quint Produções**, marca **BlackSheep Estúdio Criativo**. O CNPJ fica vazio até o owner preencher; nada é inventado. O local de trabalho é Palhoça/SC.
- Funcionária: Jheneffe, vinculada ao `admin_user` dela pelo owner. Nenhum UUID de usuário vai hardcoded.
- Jornada: segunda a sexta, 13:15–19:15. Sábado e domingo sem jornada. Timezone `America/Sao_Paulo`.

### Vigência

`employment_schedules` tem `effective_from` e `effective_to` (datas locais, intervalo semiaberto) e uma exclusion constraint impede sobreposição por funcionário. Alterar a jornada cria uma nova versão. A versão antiga continua valendo para o período dela.

### Competência

Sempre o mês civil: `period_start` é o dia 1 e `period_end` é o último dia do mês, na timezone da empregadora. Não existem `payroll_period_start_day` nem `payroll_period_end_day`.

## 5. Segurança

1. **Nenhuma escrita direta.** `anon` e `authenticated` não têm privilégio no schema `workforce`. RLS fica habilitada e forçada, sem policies. RLS restringe linhas, não colunas, por isso a defesa principal é a ausência de grants, e não as policies.
2. **Comandos governados.** Toda mutação passa por uma RPC `public.service_workforce_<comando>`: `SECURITY DEFINER`, `set search_path = ''`, `EXECUTE` só para `service_role`. Só as Edge Functions do módulo chamam essas RPCs.
   - `workforce-employee`: superfície da funcionária.
   - `admin-workforce`: superfície do owner.
3. **Identidade derivada no servidor.** A Edge Function valida o JWT e resolve o `admin_user_id`. A RPC recebe só esse ator e deriva o resto:
   - para a funcionária, `tenant_id`, `employer_id` e `employee_id` vêm do vínculo `employees.admin_user_id`;
   - para o owner, o tenant vem da membership OWNER ativa, e todo `employer_id`/`employee_id`/`exception_id` informado é revalidado contra esse tenant.

   Os campos `tenant_id`, `organization_id`, `employer_id`, `employee_id`, `source`, `status`, `classification`, `duration_minutes` e `created_by` **nunca** são aceitos do browser. Payloads com chaves desconhecidas são rejeitados (`WORKFORCE_PAYLOAD_FIELD_FORBIDDEN`).
4. **Separação de papéis na RPC.** Comandos owner verificam `role = 'OWNER'` e a membership no tenant dentro da própria RPC. Manipular o frontend não basta: a Edge Function e a RPC checam de novo.
5. **Timestamps autoritativos.** Início e fim ao vivo usam `now()` do banco. No retroativo, o período informado fica em `reported_start`/`reported_end` e o momento real do registro em `created_at`.
6. **Idempotência.** Todo comando mutável recebe uma `idempotency_key` gerada pelo cliente. `workforce.command_receipts (actor, command, key)` é único e devolve o resultado original na repetição. Além disso, o índice parcial único `work_exceptions (employee_id) where status = 'OPEN'` garante um único período aberto, mesmo com duplo clique ou requisições concorrentes.
7. **Imutabilidade.** Horário bruto, snapshots de fechamento e a trilha de auditoria são protegidos por triggers contra `UPDATE`/`DELETE`. Correções e reclassificações criam linhas novas.
8. **Isolamento de tenant.** Toda FK de domínio carrega `tenant_id` e é coerente com ele (FKs compostas `(tenant_id, id)`). Os testes provam que o tenant A não lê, não altera, não fecha e não gera relatório do tenant B.

## 6. Papéis

| Ação | Funcionária | Owner |
| --- | --- | --- |
| Iniciar/finalizar trabalho extraordinário | ✅ | — |
| Registrar retroativo, atraso, saída antecipada, ausência | ✅ (próprios) | ✅ (ocorrência administrativa) |
| Ver próprios registros e espelho | ✅ | ✅ (todos do tenant) |
| Dar ciência, contestar, solicitar correção | ✅ | contestar (`MANAGER_CONTESTED`, motivo obrigatório) |
| Revisar correções e classificar | — | ✅ |
| Revisar alertas de conformidade | — | ✅ |
| Fechar, reabrir (motivo obrigatório), gerar PDF | — | ✅ |
| Configurar empregadora, funcionário, jornada, contadora, feriados | — | ✅ |
| Ver auditoria e envios | — | ✅ |

O owner **nunca** apaga hora registrada pela funcionária. Para discordar, ele contesta.

## 7. Registro de exceções

- Tipos: `EXTRA_WORK`, `EARLY_LEAVE`, `LATE_ARRIVAL`, `ABSENCE`, `MEDICAL_LEAVE`, `OTHER`.
- Origens: `EMPLOYEE`, `MANAGER`, `RETROACTIVE_EMPLOYEE`, `RETROACTIVE_MANAGER`, `SYSTEM_SUGGESTION`.
- Estados: `OPEN`, `RECORDED`, `PENDING_REVIEW`, `VALIDATED`, `MANAGER_CONTESTED`, `CORRECTION_REQUESTED`, `WITHDRAWN_BY_EMPLOYEE`. Não existe `CANCELLED` genérico.
- `event_date` é a data local do **início** do período. A apuração pode gerar segmentos em mais de uma data.

## 8. Apuração

A apuração é a interseção do período registrado com a jornada vigente na data local de cada trecho. Nunca é `fim − início`.

1. O intervalo é recortado na meia-noite local, gerando um trecho por data.
2. Cada data recebe uma classe de dia, nesta precedência: `HOLIDAY` > `SUNDAY` > `SATURDAY` > `WEEKDAY`. Feriado é qualquer `workforce.holidays` aplicável ao estabelecimento da empregadora (nacional, estadual ou municipal).
3. Em dia com jornada, o trecho vira `EXTRA_BEFORE`, `REGULAR_OVERLAP` e `EXTRA_AFTER`. Em dia sem jornada (fim de semana ou feriado), vira `EXTRA_NON_WORKDAY`.
4. Classificação operacional dos minutos extras: `EXTRA_WEEKDAY`, `EXTRA_SATURDAY`, `EXTRA_SUNDAY`, `EXTRA_HOLIDAY`.
5. A tolerância (`payroll_settings`) só existe nesta camada. O horário bruto nunca é arredondado. O padrão é zero (nenhuma tolerância aplicada) até o owner configurar.

Matriz obrigatória, com jornada 13:15–19:15:

| Caso | Registro | Resultado |
| --- | --- | --- |
| 1 | terça 08:00–10:00 | 120 min `EXTRA_BEFORE` / `EXTRA_WEEKDAY` |
| 2 | terça 18:00–20:00 | 75 min `REGULAR_OVERLAP` + 45 min `EXTRA_AFTER` |
| 3 | terça 12:00–14:00 | 75 min `EXTRA_BEFORE` + 45 min `REGULAR_OVERLAP` |
| 4 | sábado 09:00–13:00 | 240 min `EXTRA_SATURDAY` |
| 5 | domingo 09:00–13:00 | 240 min `EXTRA_SUNDAY` |
| 6 | feriado (segunda) 09:00–12:00 | 180 min `EXTRA_HOLIDAY` |
| 7 | sexta 23:00 – sábado 02:00 | 60 min `EXTRA_AFTER`/`EXTRA_WEEKDAY` (sexta) + 120 min `EXTRA_SATURDAY` (sábado); `event_date` = sexta |

Atraso, saída antecipada e ausência **não** geram saldo negativo. O owner classifica cada ocorrência como `AUTHORIZED`, `EXCUSED`, `DEDUCTIBLE` ou `INFORMATIONAL`, e não há desconto automático no V1. Mudar a classificação cria uma linha nova (`effective_at`, `superseded_at`, `classified_by`).

## 9. Ciência, contestação e correção

- A funcionária dá ciência (`ACKNOWLEDGED`) ou contesta (`CONTESTED`). O owner pode contestar (`MANAGER_CONTESTED`, motivo obrigatório).
- O fluxo de correção é: registro original → pedido de correção (`proposed_event_date`, `proposed_type`, `proposed_start`, `proposed_end`, `reason`) → revisão (aprovar ou rejeitar; a funcionária pode desistir). Aprovar cria uma nova interpretação. O original continua intacto e auditável.
- Contestação aberta ou correção pendente bloqueiam o fechamento.

## 10. Conformidade (revisão, não veredito)

Os alertas são de **revisão** e todos os limites são parâmetros por empregadora:

| Alerta | Parâmetro inicial |
| --- | --- |
| `EXTRA_DAILY_LIMIT_REVIEW` | `max_extra_minutes_per_day = 120` (CLT art. 59, parametrizado) |
| `INTERJOURNEY_REST_REVIEW` | `minimum_interjourney_rest_minutes = 660` (CLT art. 66) |
| `WEEKLY_REST_REVIEW` | `minimum_weekly_rest_minutes = 1440` (CLT art. 67) |
| `INTRAJOURNEY_INTERVAL_REVIEW` | `minimum_long_interval_minutes = 60` (CLT art. 71, conforme contrato/CCT) |
| `SPLIT_SHIFT_REVIEW` | `split_shift_review_threshold_minutes` (configurável; revisão, nunca "violação") |

A Súmula 437 do TST não é usada como fundamento vigente: as regras de intervalo seguem o art. 71 da CLT, com a redação da Lei 13.467/2017, o contrato e a CCT.

Os alertas têm chave natural única `(employee_id, alert_type, reference_date)`, então recalcular é idempotente. Alerta `OPEN` exige ciência do owner e bloqueia o fechamento.

## 11. Fechamento

- Estados do período: `OPEN`, `READY_TO_CLOSE`, `BLOCKED`, `CLOSED`, `REOPENED`.
- Bloqueiam o fechamento:
  - exceção `OPEN`;
  - contestação aberta;
  - correção pendente;
  - divergência;
  - alerta sem ciência;
  - inconsistência crítica (por exemplo, empregadora sem CNPJ).
- Fechar grava um snapshot imutável (`jsonb` + hash SHA-256) com exatamente o que será reportado e incrementa `version`.
- Reabrir exige motivo. O próximo fechamento gera `version + 1`, e versões antigas nunca são sobrescritas.
- O diff entre versões lista registros adicionados, removidos e alterados (classificação, duração, período).

## 12. Relatório e PDF

O PDF é gerado a partir do snapshot fechado.

- **Cabeçalho:** razão social, CNPJ, competência, nome da funcionária e jornada vigente.
- **Linhas:** data, dia, período, classificação, duração apurada e status.
- **Totais:** extra em dia útil, sábado, domingo e feriado. Sem valores monetários.

**Nunca** entram no PDF, no e-mail ou em log de erro:

- observação livre;
- motivo familiar;
- informação médica, diagnóstico ou CID;
- nota interna do owner.

O snapshot de relatório é um payload separado, sem essas colunas.

## 13. Envio

- **Disparo:** às 16:00 (`America/Sao_Paulo`) do **2º dia útil** do mês seguinte. Contam como não úteis sábados, domingos e feriados nacionais, estaduais e municipais do estabelecimento da empregadora.
- **Sem pendência:** fecha, gera o snapshot, gera o relatório/PDF, envia à contadora (`accountant_email` e, se houver, `accountant_email_secondary`) e envia o comprovante à funcionária.
- **Com pendência:** o período fica `BLOCKED` e nada é enviado. Quando a última pendência é resolvida depois do horário, o próximo ciclo do worker revalida, fecha e envia, sem esperar o mês seguinte.
- **Falha de envio:** fechamento e envio são estados independentes. Uma falha deixa `closure = CLOSED` e `delivery = FAILED`, e **nunca** reabre a competência. O worker tenta de novo até 3 vezes.
- **Idempotência:** a chave única é `(closure_id, version, recipient, kind)`, então o mesmo relatório nunca sai duas vezes.
- **Comprovantes externos à funcionária:** registro concluído, ocorrência do owner sobre ela, correção aprovada ou rejeitada, contestação do owner e competência fechada. Nunca a cada clique intermediário.
- **Provedor:** Resend, via `_shared/email-provider.ts`. Os secrets ficam só no servidor. Os testes usam provedor fake.
- **Ativação:** o workflow de schedule fica separado das migrations e só passa a valer depois do merge final em `main`, com autorização. O envio real exige configuração explícita (`auto_send_enabled`).

## 14. Privacidade (LGPD)

Não são coletados:

- GPS ou localização;
- selfie;
- biometria;
- CID;
- arquivo ou imagem de atestado.

`MEDICAL_LEAVE` é só um tipo de ocorrência. Observações ficam em colunas próprias, visíveis apenas à funcionária e ao owner, e nunca são copiadas para relatório, e-mail, auditoria de erro ou `audit_logs` gerais.

## 15. Slices

| Slice | Escopo | Branch (agenda / black-sheep) |
| --- | --- | --- |
| S0 | Auditoria, baseline, CI de integração | `agenda-workforce-s0-baseline` |
| S1 | Employer, employee, jornada versionada, payroll settings, feriados | `agenda-workforce-s1-foundation` |
| S2 | Registro governado de exceções | `agenda-workforce-s2-exceptions` |
| S3 | Motor de apuração (segmentos) | `agenda-workforce-s3-calculation` |
| S4 | Ciência, contestação, correção, classificação versionada | `agenda-workforce-s4-review` |
| S5 | Alertas de conformidade | `agenda-workforce-s5-compliance` |
| S6 | Fechamento, snapshots, versões, diff | `agenda-workforce-s6-closure` |
| S7 | Interface e PDF | `agenda-workforce-s7-ui` |
| S8 | Entrega por e-mail e automação | `agenda-workforce-s8-delivery` |

## 16. Fora do V1

Não fazem parte do V1:

- detector de atividade fora do horário (Kommo/Dracma);
- GPS e biometria;
- folha e financeiro de RH;
- eSocial;
- banco de horas e `COMPENSATED`;
- anexo de atestado;
- cálculos de salário-hora, 50%/100%, DSR, FGTS, INSS, IRRF, adicional noturno e reflexos.

Esses cálculos continuam com a contadora.

## 17. Decisões adiadas

- Delegar ações owner a ADMIN por permissão explícita (`WORKFORCE_MANAGE`). No V1, só OWNER.
- Tolerância padrão (art. 58 §1 da CLT, 5 min por marcação e até 10 min no dia): o parâmetro existe, mas o padrão é 0 até o owner confirmar com a contadora.
- Feriados estaduais de SC e municipais de Palhoça: a estrutura existe, mas as datas são cadastradas e confirmadas pelo owner. Só os feriados nacionais de lei federal entram como seed.
