# BlackSheep Agenda — Mapa Funcional V1.12

**Data:** 23/08/2026  
**Base:** V1.11  
**Escopo:** Sabrina Pierri + BlackSheep Estúdio Criativo  
**Regra de precedência:** a V1.12 preserva a V1.11 exceto nos pontos explicitamente substituídos abaixo.

---

# 1. Comunicação e CRM — nova arquitetura da V1

A Agenda deixa de possuir integração direta própria com WhatsApp na V1.

A responsabilidade passa a ser separada assim:

- **BlackSheep Agenda:** fonte autoritativa de reserva, disponibilidade, pagamento, política, cancelamento e remarcação;
- **Kommo:** CRM externo e camada de comunicação da operação BlackSheep;
- **Google Calendar:** espelho de agenda/bloqueios conforme integração específica;
- **Mercado Pago:** provedor financeiro conforme integração específica.

A Agenda não se transforma em CRM avançado. Ela apenas mantém o vínculo técnico necessário para espelhar reservas BlackSheep no Kommo.

---

# 2. Escopo por operação

A integração Kommo é elegível **somente** quando o serviço possuir:

`operation_scope = BLACKSHEEP`

Serviços com:

`operation_scope = SABRINA`

não devem criar contato, lead, atividade, mensagem ou e-mail no Kommo por meio da Agenda.

Serviços sem classificação explícita também não são elegíveis.

## 2.1 BlackSheep

Para reservas BlackSheep:

- a pessoa é representada por um **Contato** no Kommo;
- cada reserva é representada por **um Lead próprio**;
- uma nova reserva do mesmo cliente pode gerar outro Lead, reutilizando o mesmo Contato;
- cancelamento e remarcação atualizam o **mesmo Lead da reserva**;
- o identificador autoritativo de correlação é o `appointment_id` da Agenda;
- notificações por WhatsApp e e-mail são responsabilidade das automações do Kommo;
- a caixa operacional definida para agendamentos é `agenda@blacksheepestudiocriativo.com.br`.

## 2.2 Sabrina

Por decisão operacional atual:

- não há integração Kommo para Sabrina;
- não há confirmação automática por e-mail para Sabrina;
- a Agenda continua registrando e operando a reserva normalmente;
- essa ausência de comunicação externa não altera a validade da reserva.

Qualquer ativação futura para Sabrina exige decisão explícita e nova revisão normativa.

---

# 3. Fluxo BlackSheep → Kommo

O fluxo da V1 é **unidirecional**:

`Agenda → Kommo`

A Agenda permanece autoridade. Falha ou indisponibilidade do Kommo nunca pode impedir a criação, pagamento, remarcação ou cancelamento de uma reserva na Agenda.

O espelhamento deve utilizar outbox/retry idempotente.

Estados/eventos relevantes:

- reserva criada / aguardando pagamento;
- pagamento confirmado;
- remarcação;
- cancelamento;
- conclusão;
- no-show;
- expiração, quando aplicável ao estágio configurado.

A atualização de data/horário por remarcação deve manter o mesmo `kommo_lead_id`.

O Kommo pode usar mudança de estágio para acionar Salesbot, WhatsApp e/ou e-mail. A regra de comunicação fica no CRM, não no domínio transacional da Agenda.

---

# 4. Vínculos externos

A Agenda pode persistir exclusivamente os identificadores necessários à correlação:

- `customer_id ↔ kommo_contact_id`;
- `appointment_id ↔ kommo_lead_id`;
- versão/status do último sync.

Credenciais do Kommo não podem ser persistidas nessas tabelas. Token privado/long-lived deve existir somente em secret server-side.

A integração deve iniciar desabilitada até o provider spike e a configuração real da conta/pipeline serem aprovados.

---

# 5. Remarcação e cancelamento

## 5.1 Remarcação

Remarcar uma reserva:

1. altera a reserva autoritativa na Agenda;
2. mantém o mesmo `appointment_id`;
3. mantém o mesmo Lead Kommo;
4. atualiza data, horário, serviço/valor quando aplicável;
5. emite evento de sync `RESCHEDULED` para permitir notificação no Kommo.

Não é criado novo Lead apenas por remarcação.

## 5.2 Cancelamento

Cancelar uma reserva:

1. executa primeiro a política financeira/autoritativa na Agenda;
2. mantém o histórico do Lead existente;
3. move/atualiza o mesmo Lead para o estado configurado de cancelamento;
4. permite que o Kommo comunique o cliente conforme automação configurada.

Excluir Lead ao cancelar é proibido: o histórico comercial deve ser preservado.

---

# 6. Recuperação de checkout expirado — substituição da V1.11

A seção 5 da V1.11 é substituída.

A recuperação proativa por WhatsApp direto da Agenda sai da V1.

Consequências:

- não há envio direto da Agenda para Meta/WhatsApp;
- o checkbox de autorização para recuperação de checkout por WhatsApp é retirado do checkout;
- holds expirados continuam expirando e liberando recursos/pacotes normalmente;
- nenhuma mensagem é enfileirada pela Agenda por abandono de checkout;
- uma seleção abandonada antes de virar reserva **não cria Lead Kommo automaticamente**.

Recuperação/nurturing de abandono poderá ser avaliada depois como automação comercial separada, sem comprometer a autoridade de disponibilidade da Agenda.

---

# 7. E-mail BlackSheep

A caixa operacional de reservas BlackSheep é:

`agenda@blacksheepestudiocriativo.com.br`

Na arquitetura aprovada, a Agenda não precisa possuir provedor SMTP próprio para as notificações rotineiras se o Kommo estiver responsável por enviá-las.

A conexão/autorização da caixa no Kommo é uma configuração externa e deve ser validada no gate do provedor antes de ser marcada como operacional.

---

# 8. Fora da V1 / limites

Continuam fora da V1:

- CRM próprio dentro da Agenda;
- automação de marketing própria da Agenda;
- sincronização bidirecional Kommo → Agenda;
- alteração/cancelamento de reserva originado diretamente pelo Kommo;
- campanhas criadas ou executadas pela Agenda;
- recuperação avançada de carrinho;
- integração WhatsApp direta com Meta pela Agenda.

O uso futuro dos contatos do Kommo em campanhas BlackSheep é uma capacidade do CRM externo, não uma feature do motor de agenda.

---

# 9. Gate para ativação Kommo

Antes de `enabled = true`:

1. criar/selecionar integração privada Kommo;
2. armazenar token somente como secret server-side;
3. confirmar subdomínio da conta;
4. confirmar pipeline e IDs de etapas;
5. executar spike com dados sintéticos;
6. provar criação/identificação de Contato;
7. provar criação de um Lead sintético;
8. provar atualização do mesmo Lead em remarcação e cancelamento;
9. provar idempotência/retry sem duplicar Lead;
10. somente depois habilitar a geração/consumo dos jobs de produção da integração.

Até esse gate passar, a fundação Kommo permanece instalada porém desabilitada.

---

# 10. Registro da decisão

Decisão aprovada em 23/08/2026:

- substituir integração WhatsApp própria por Kommo para a operação BlackSheep;
- aproveitar o Kommo também como CRM dos clientes de locação e base futura de campanhas;
- usar `agenda@blacksheepestudiocriativo.com.br` como caixa operacional de agendamento BlackSheep;
- manter Sabrina sem Kommo e sem confirmação por e-mail por enquanto.
