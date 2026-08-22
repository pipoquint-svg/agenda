# BlackSheep Agenda — Mapa Funcional V1.11 — Emenda de Escopo

**Status:** Normativo — decisão funcional posterior à auditoria retroativa de 22/08/2026  
**Base:** Mapa Funcional V1.8 + decisões humanas registradas em 22/08/2026  
**Escopo:** Sabrina Pierri + BlackSheep Estúdio Criativo  
**Autoridade:** esta emenda altera explicitamente o escopo funcional da V1 nos pontos abaixo e prevalece sobre trechos conflitantes da V1.8 até a consolidação do documento mestre integral.

---

# 1. Objetivo desta emenda

A auditoria retroativa confirmou que parte do código desenvolvido corretamente não estava refletida no Mapa Funcional V1.8. As decisões abaixo foram aprovadas explicitamente e passam a integrar a V1.

Nenhuma destas decisões transforma a Agenda em SaaS ou multi-workspace.

---

# 2. Clientes com condições comerciais especiais

A V1 passa a permitir condições comerciais permanentes por cliente quando configuradas administrativamente.

Inclui:

- `billing_mode = CHECKOUT | INVOICE`;
- `invoice_due_days` configurável por cliente;
- autorização de pré-reserva por cliente;
- limite de pré-reservas simultâneas por cliente;
- lista de serviços autorizados para pré-reserva;
- confirmação manual quando configurada;
- auditoria de alterações desses termos.

## Regra de segurança

Nenhum cliente recebe estas condições por inferência, nome, empresa ou seed automático.

Toda ativação é explícita e auditada.

## Pré-reserva

A pré-reserva só poderá ser descrita como horário protegido quando houver alocação autoritativa de recursos pelo mesmo mecanismo de integridade da agenda normal.

Enquanto essa implementação não estiver concluída, a UI não pode prometer bloqueio de horário.

## Faturamento

O modo `INVOICE` permite confirmação administrativa sem checkout Mercado Pago.

O vencimento usa prazo configurável por cliente, mas a base temporal do vencimento deve ser definida explicitamente antes de ativação real: data do serviço, data da confirmação ou data de emissão. Não inferir silenciosamente.

---

# 3. Locação BlackSheep por duração

A locação BlackSheep passa a ser tratada como um único serviço com duração variável.

## Modelo

- `duration_mode = BLOCKS` para serviços de locação configurados dessa forma;
- bloco-base de 30 minutos na V1 atual;
- mínimo e máximo configuráveis;
- cliente pode selecionar qualquer quantidade válida de blocos;
- buffer pertence ao serviço completo e é aplicado uma única vez após o período contratado;
- buffer não é cobrado e não consome pacote de horas.

Serviços Sabrina e outros serviços podem permanecer em `duration_mode = FIXED`.

---

# 4. Presets comerciais de duração

A V1 inclui presets editoriais de duração para facilitar escolha do cliente.

Na locação BlackSheep, os presets de referência podem incluir:

- 1h;
- 2h;
- 4h;
- 8h.

Presets:

- são recomendações comerciais;
- não são serviços distintos;
- não impedem outras durações válidas;
- podem possuir título, descrição, selo e destaque;
- devem continuar usando o mesmo motor autoritativo de preço e disponibilidade.

---

# 5. Preço progressivo por duração

A V1 inclui faixas de preço por quantidade de blocos para serviços de duração variável.

Regras:

- faixas são configuráveis;
- sobreposição ambígua é proibida;
- preço final continua calculado no backend;
- presets não definem preço por si mesmos;
- pricing por duração entra antes das demais regras aplicáveis de preço;
- ausência de faixa pode usar o fallback configurado do serviço.

---

# 6. Dashboard administrativo

A V1 inclui Dashboard operacional no hub de Gestão.

Inclui:

- reservas no período;
- novos agendamentos;
- cancelamentos;
- remarcações;
- resumo por profissional;
- Centro de Pendências tipado a partir de estados reais do backend;
- filtro explícito de operação `BLACKSHEEP | SABRINA | ALL`.

Nenhum indicador pode ser criado por heurística de nome ou status textual.

---

# 7. Indicador de ocupação

A V1 inclui percentual de ocupação, mas sua ativação depende de configuração explícita do recurso físico usado como denominador.

Regras:

- não inferir recurso pelo nome;
- somente recurso físico elegível pode ser selecionado;
- sem recurso configurado, retornar `ocupação não configurada`;
- não exibir `0%` como substituto para ausência de configuração;
- sobreposição ou exceção que torne o denominador ambíguo deve produzir estado indisponível, não número estimado.

A escolha do recurso real permanece validação humana/configuração operacional antes do live.

---

# 8. Recuperação simples de checkout expirado

A V1 inclui recuperação simples após expiração de checkout hold.

Quando o hold expira depois que o telefone já foi informado, o sistema pode enviar uma única mensagem transacional com link opaco para retomar o contexto.

Essa recuperação:

- não ressuscita o hold expirado;
- não promete o horário anterior;
- não cria fila de espera;
- não gera prioridade;
- não cria reserva;
- recalcula disponibilidade ao retomar;
- não expõe PII no token/contexto público;
- deve ser idempotente.

Isso não altera a exclusão de recuperação avançada de carrinho/marketing automation da V1.

---

# 9. Estratégia Amelia

A decisão operacional vigente é:

- reservas criadas originalmente no Amelia continuam sob autoridade operacional do Amelia até serem cumpridas;
- a BlackSheep Agenda mantém histórico dessas reservas em modo somente leitura;
- importação de legado não cria `appointments`, `resource_allocations`, pagamentos ou jobs gerenciados pela nova Agenda;
- eventos Amelia existentes no Google continuam entrando como bloqueios externos pelo mecanismo normal de sincronização;
- novos agendamentos após a virada pública são autoridade exclusiva da BlackSheep Agenda.

Essa decisão substitui a estratégia anterior de migrar todas as reservas futuras do Amelia para o domínio nativo antes da virada.

---

# 10. Itens que continuam fora da V1

Continuam fora da V1, sem alteração:

- multi-workspace;
- SaaS/multi-tenancy;
- CRM avançado e tags complexas;
- capacidade compartilhada por sessão;
- fila de espera;
- recuperação avançada de carrinho;
- marketing automation;
- NFS-e automática;
- editor visual completo de tema;
- área logada do cliente;
- app nativo;
- programa de fidelidade;
- assinaturas;
- IA.

A existência de condições comerciais especiais por cliente, aprovada nesta emenda, é uma exceção explícita à antiga exclusão genérica de “benefício permanente por cliente”. A exceção é restrita às regras documentadas no item 2 e não autoriza benefícios arbitrários.

---

# 11. Regra de autoridade após esta emenda

Para as decisões descritas neste documento:

1. esta emenda V1.11 é a autoridade funcional;
2. contratos técnicos/ADRs devem realizá-la sem alterar a regra comercial;
3. modelo de dados e interface devem refletir a mesma decisão;
4. qualquer nova divergência exige nova decisão explícita antes de código.

---

# 12. Pendências que esta emenda NÃO aprova

Esta emenda não declara como prontas:

- pré-reserva autoritativa de recursos;
- definição da base temporal do vencimento de INVOICE;
- escolha real do recurso-base de ocupação;
- testes reais de Mercado Pago sandbox;
- testes reais de Google Calendar;
- testes em dispositivos físicos;
- branch protection;
- testes adversariais da superfície pública;
- rate limiting distribuído.

Esses itens permanecem sujeitos aos gates e frentes pós-auditoria.