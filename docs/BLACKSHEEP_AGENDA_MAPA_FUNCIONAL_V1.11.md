# BlackSheep Agenda — Mapa Funcional V1.11

**Status:** atualização normativa pós-auditoria retroativa de 22/08/2026  
**Base:** Mapa Funcional V1.10  
**Escopo:** Sabrina Pierri + BlackSheep Estúdio Criativo  
**Regra de precedência:** esta V1.11 preserva integralmente a V1.10, exceto nos pontos explicitamente substituídos abaixo. Em conflito sobre regra de negócio ou operação, esta V1.11 prevalece.

---

# 1. Decisões de escopo aprovadas após auditoria retroativa

A auditoria de conformidade encontrou funcionalidades implementadas posteriormente à V1.10 que tinham decisão operacional registrada, mas não haviam sido propagadas ao Mapa Funcional. Em 22/08/2026 foi decidido incorporá-las oficialmente à V1.

Entram formalmente na V1:

1. pré-reserva autorizada e faturamento a prazo para clientes comerciais explicitamente configurados;
2. locação BlackSheep por duração em blocos de 30 minutos, com presets editoriais e preço progressivo por duração;
3. Dashboard administrativo com Centro de Pendências, indicadores operacionais e ocupação quando houver recurso-base explicitamente configurado;
4. recuperação simples de checkout expirado, sem promessa de vaga e sem ressuscitar hold;
5. estratégia Amelia legado: reservas antigas permanecem sob autoridade operacional do Amelia até serem cumpridas; a nova Agenda não adota essas reservas como nativas.

Nenhuma dessas decisões transforma a V1 em SaaS, CRM avançado, fila de espera ou programa de fidelidade.

---

# 2. Clientes comerciais — pré-reserva e faturamento a prazo

A regra geral continua sendo checkout normal ou liberação administrativa pontual. Como exceção operacional explícita da V1, determinados clientes comerciais podem receber termos comerciais persistentes configurados individualmente por administrador autorizado.

Podem existir, por cliente:

- autorização para pré-reserva;
- serviços autorizados;
- limite simultâneo de pré-reservas;
- prazo da pré-reserva;
- confirmação manual obrigatória;
- `billing_mode = CHECKOUT | INVOICE`;
- `invoice_due_days`.

Esses termos:

- não são concedidos automaticamente;
- não podem ser inferidos por nome, empresa ou histórico;
- exigem configuração explícita e auditada;
- alterações financeiras exigem permissão financeira;
- não equivalem a fidelidade, desconto permanente ou benefício promocional genérico.

## 2.1 Pré-reserva autoritativa

Uma pré-reserva só pode ser apresentada como horário protegido quando possuir alocação autoritativa de recurso usando o mesmo motor de disponibilidade/buffers da agenda normal.

Enquanto isso não estiver implementado, a UI deve deixar claro que o registro comercial não garante bloqueio do horário.

A confirmação deve converter a pré-reserva atomicamente em reserva, sem janela de corrida entre liberação e nova ocupação.

## 2.2 INVOICE

`INVOICE` não usa checkout Mercado Pago para aquela cobrança.

A base do vencimento deve ser definida e persistida explicitamente antes de ativar faturamento real. Não inferir automaticamente se o prazo conta de atendimento, confirmação ou emissão.

`invoice_due_days` nunca recebe default silencioso.

---

# 3. Locação BlackSheep por duração

A locação BlackSheep na V1 pode operar como um único serviço de duração variável.

## 3.1 Unidade

A unidade de contratação da locação é um bloco de 30 minutos.

O serviço pode definir:

- `duration_mode = BLOCKS`;
- tamanho do bloco;
- mínimo de blocos;
- máximo de blocos;
- duração contratada resultante.

Serviços que não usam duração variável continuam em `FIXED`.

## 3.2 Buffer

O buffer pertence ao serviço inteiro e é aplicado uma única vez antes/depois do período contratado conforme configuração.

Buffer não é tempo vendido e não é multiplicado pela quantidade de blocos.

## 3.3 Presets editoriais

A V1 pode oferecer presets/recomendações como:

- 1h;
- 2h;
- 4h;
- 8h.

Preset é atalho editorial. Ele não cria um serviço diferente e não impede outras durações válidas em incrementos permitidos.

## 3.4 Preço progressivo por duração

A locação pode possuir faixas de preço por quantidade de blocos, permitindo redução do preço unitário conforme a duração aumenta.

As faixas:

- são configuráveis;
- não podem se sobrepor;
- são resolvidas no backend;
- precedem as demais regras de preço aplicáveis;
- nunca tornam o frontend autoridade do valor final.

---

# 4. Dashboard administrativo V1

O Dashboard pode incluir:

- quantidade de reservas;
- minutos contratados;
- novos agendamentos;
- cancelamentos;
- remarcações;
- resumo por profissional;
- Centro de Pendências tipado;
- ocupação quando calculável com segurança.

## 4.1 Centro de Pendências

Pendências devem derivar de estados reais do backend. Não inferir por texto, nome de status ou heurística visual.

Pendências financeiras respeitam `FINANCE_VIEW`.

## 4.2 Ocupação

A taxa de ocupação só pode ser exibida quando existir um recurso físico-base explicitamente configurado.

Sem recurso-base:

`OCCUPANCY_RESOURCE_NOT_CONFIGURED`

A interface não deve transformar ausência de configuração em `0%`.

Se regras de disponibilidade/exceções tornarem o denominador ambíguo, a taxa fica indisponível em vez de inventada.

---

# 5. Recuperação simples de checkout expirado

Entra na V1 uma recuperação simples e transacionalmente segura de checkout abandonado.

Quando um checkout hold expirar depois que houver contato autorizado para recuperação, o sistema pode enviar uma única mensagem com link opaco para retomar contexto.

A recuperação:

- não ressuscita o hold antigo;
- não promete o horário anterior;
- não cria fila de espera;
- não cria prioridade;
- não bloqueia recurso;
- recalcula disponibilidade no retorno;
- não expõe PII no token/contexto público;
- deve ser idempotente.

Recuperação avançada de carrinho, nurturing e automação de marketing continuam fora da V1.

---

# 6. Amelia — estratégia de transição substitutiva

Esta seção substitui a estratégia anterior da V1.10 que previa adoção das reservas futuras do Amelia como reservas nativas antes do go-live.

## 6.1 Autoridade das reservas antigas

Reservas criadas no Amelia antes da virada permanecem sob autoridade operacional do Amelia até sua conclusão.

A BlackSheep Agenda pode manter histórico/snapshot dessas reservas, mas a importação:

- não cria `appointments` nativos;
- não cria `resource_allocations` nativas em nome da reserva Amelia;
- não cria pagamentos nativos;
- não cria eventos Google gerenciados pela Agenda para essas reservas;
- não assume remarcação/cancelamento operacional dessas reservas.

Eventos Amelia já existentes no Google continuam sendo percebidos pelo sync normal como bloqueios externos relevantes.

## 6.2 Go-live

Após a virada:

- novas reservas usam exclusivamente a BlackSheep Agenda;
- reservas Amelia existentes continuam sendo operadas no Amelia até acabarem;
- o histórico Amelia fica disponível separadamente, em modo somente leitura na nova administração;
- não existe migração destrutiva ou adoção obrigatória de reservas em andamento.

Essa estratégia reduz risco de cobrança duplicada, evento duplicado e divergência de estado durante a transição.

---

# 7. Substituição da seção 64 — Fora da V1

Permanecem deliberadamente fora da V1:

- multi-workspace;
- SaaS;
- multi-tenancy;
- CRM avançado;
- tags complexas;
- benefícios promocionais/fidelidade permanentes e genéricos por cliente;
- capacidade compartilhada por sessão;
- fila de espera;
- recuperação avançada de carrinho;
- automação de marketing;
- emissão automática de NFS-e;
- editor visual completo de tema;
- área de cliente com login;
- app nativo;
- programa de fidelidade;
- assinaturas;
- IA.

**Exceção explicitamente incorporada à V1:** termos comerciais persistentes e auditados para clientes comerciais autorizados, limitados à pré-reserva e faturamento a prazo descritos na seção 2 desta V1.11. Isso não autoriza descontos, fidelidade ou privilégios comerciais genéricos fora dessa finalidade.

---

# 8. Decisões que continuam pendentes

A V1.11 não define por inferência:

- qual cliente real recebe INVOICE;
- qual é a base temporal de `invoice_due_days`;
- qual recurso físico real será o denominador da ocupação;
- valores comerciais reais de políticas, preços, tiers ou presets quando ainda não configurados.

Esses itens exigem decisão/configuração explícita antes de ativação.

---

# 9. Registro de origem

Decisões aprovadas em 22/08/2026 após a Frente 1 da auditoria de conformidade de escopo.

Referências de implementação já existentes:

- Agenda PRs #41, #46, #47, #48 — duração variável/presets/pricing;
- Agenda PRs #61, #62, #64 — clientes comerciais/pré-reserva/INVOICE;
- Agenda PRs #67, #69 — Dashboard/ocupação;
- Agenda PR #32 — recuperação simples de checkout;
- Agenda PR #34 / ADR-014 — Amelia histórico somente leitura;
- auditoria retroativa #70 e hardening #71;
- BlackSheep hardening #17.

Nenhuma feature nova é introduzida por este documento. Ele formaliza decisões já tomadas e corrige a autoridade normativa antes da continuação do desenvolvimento.