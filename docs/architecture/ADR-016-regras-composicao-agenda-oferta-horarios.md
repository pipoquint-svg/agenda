# ADR-016 — Regras de Composição de Agenda e Oferta de Horários

**Status:** PROPOSTO PARA AUDITORIA — NÃO IMPLEMENTAR ANTES DA APROVAÇÃO  
**Data:** 23/08/2026  
**Escopo:** motor de disponibilidade da BlackSheep Agenda  
**Substitui:** nenhum ADR anterior  
**Complementa:** regras atuais de disponibilidade, recursos, fases, buffers e checkout hold

---

## 1. Contexto

O estúdio é um recurso físico único compartilhado por serviços de naturezas diferentes:

- ensaios com regras próprias de horário e profissional;
- locações com duração contratada variável;
- extras que podem criar fases adicionais de ocupação antes ou depois do núcleo do serviço.

O problema operacional observado é a fragmentação ruim do dia: uma reserva curta em posição inadequada dentro de um período vazio pode impedir locações maiores e ensaios posteriores, mesmo quando haveria posições alternativas comercialmente equivalentes para a reserva curta.

O objetivo **não** é maximizar receita por hora nem prever qual reserva futura terá maior valor.

O objetivo é:

> evitar fragmentação desnecessária e manter o espaço residual contíguo e comercializável, sem reservar capacidade futura, sem prioridade dinâmica e sem variar disponibilidade por antecedência.

---

## 2. Premissas da operação

### 2.1 Recurso físico ESTÚDIO

Blocos de composição:

- **MANHÃ:** 08h00–13h00;
- **TARDE:** 13h30–18h30;
- **NOTURNO:** 19h00–22h00.

O período 18h30–19h00 é transição entre TARDE e NOTURNO e não pertence a nenhum dos dois blocos.

Funcionamento ordinário público do estúdio:

- 08h00–22h00.

Exceções de PREP anteriores às 08h00 podem existir somente quando configuradas por serviço/extra e **não** ampliam a janela pública geral do estúdio.

### 2.2 Buffer operacional

O buffer padrão do estúdio é:

- **30 minutos APÓS a reserva**;
- **nenhum buffer automático antes**.

O buffer existe para organização/reset do estúdio e não faz parte da duração contratada pelo cliente.

O buffer não deve ser duplicado entre reservas consecutivas.

### 2.3 Duração contratada e ocupação efetiva

**Duração contratada / CORE** é o tempo adquirido pelo cliente.

Exemplo — locação de 2h às 14h00:

- `core_start_at = 14h00`;
- `core_end_at = 16h00`;
- duração contratada = 120 minutos;
- buffer operacional do estúdio = 16h00–16h30;
- ocupação efetiva do estúdio = 14h00–16h30.

Para um serviço simples sem PREP adicional:

`studio_occupied_range = [core_start_at, core_end_at + post_buffer)`

A classificação comercial de duração utiliza o CORE, não o buffer.

---

## 3. Serviços e disponibilidade operacional

### 3.1 Sabrina

Ensaios Sabrina:

- 3h, início ordinário às 09h00 ou 14h00;
- 4h, início ordinário às 09h00 ou 14h00;
- possuem restrição de **bloco íntegro para admissão**.

Com extra de maquiagem selecionado:

- uma fase PREP pode iniciar às 07h30 na manhã;
- ou às 13h30 no período da tarde, conforme configuração do serviço/extra.

A possibilidade de PREP às 07h30 existe **somente** quando o cliente contratou o extra correspondente. Ela não cria slots públicos às 07h30 para locação, Fê ou outros serviços.

### 3.2 Fê

Ensaios Fê:

- duração contratada de 1h ou 1h30;
- disponibilidade ordinária da profissional: 09h00–19h00;
- pode estender até 20h00 quando configurado;
- pausa de almoço flexível entre 12h00 e 13h30;
- quando o bloco está livre, utiliza os horários de início configurados para o serviço;
- quando o bloco está fragmentado, pode ocupar resíduos válidos junto de uma reserva existente, desde que respeite a interseção de recursos e fases.

### 3.3 Locações

Durações comerciais atuais:

- 1h;
- 2h;
- 4h;
- diária de 8h.

A locação de 4h é a mais frequente, seguida pela de 2h. A diária é rara.

Fins de semana possuem acréscimo comercial de 20%, sem alteração automática das regras de composição deste ADR.

---

## 4. Decisão proposta

São adotadas três regras independentes, avaliadas no instante da consulta de disponibilidade.

Nenhuma delas depende de:

- antecedência da reserva;
- previsão de demanda;
- prioridade financeira;
- projeção combinatória de receitas futuras.

---

## 5. Regra 1 — serviço que exige bloco íntegro para admissão

Um serviço pode declarar:

`requires_empty_block = true`

Nesse caso, o serviço só pode ser **ofertado e admitido no hold** se o bloco de composição relevante estiver sem qualquer ocupação incompatível.

Aplica-se atualmente aos ensaios da Sabrina.

### 5.1 Definição de bloco vazio

Para a admissão de um serviço `requires_empty_block`, o bloco está vazio quando não existe `occupied_range` ativo de outro uso incompatível intersectando o intervalo do bloco.

Devem contar como ocupação, conforme contrato atual do motor:

- HELD válido;
- AWAITING_PAYMENT;
- CONFIRMED;
- BLOCKED;
- EXTERNAL_ACTIVE;
- demais estados autoritativos equivalentes que impeçam uso físico.

Holds expirados não podem manter o bloco indisponível.

### 5.2 Semântica proposta para auditoria

**Proposta:** `requires_empty_block` é uma **condição de admissão**, não uma extensão artificial da ocupação.

Portanto:

1. antes da reserva Sabrina ser criada, o bloco inteiro precisa estar livre;
2. depois que a reserva existe, a ocupação física passa a ser determinada somente pelas fases/recursos efetivamente utilizados e pelo buffer posterior aplicável;
3. o restante do bloco pode ser usado por outro serviço compatível se houver encaixe real.

Exemplo:

- TARDE = 13h30–18h30;
- Sabrina 3h = 14h00–17h00;
- buffer do estúdio = 17h00–17h30;
- para Sabrina ser aceita, 13h30–18h30 precisava estar livre;
- depois da criação, a ocupação ordinária do estúdio é 14h00–17h30, salvo fases adicionais contratadas.

**Ponto obrigatório da auditoria:** validar que essa interpretação corresponde à regra de negócio desejada. Se Sabrina deve bloquear artificialmente todo o bloco mesmo após a criação, este ADR deve ser alterado antes da implementação.

---

## 6. Regra 2 — posição de reservas curtas

Definição configurável por recurso:

`short_booking_threshold_minutes = 150`

Um serviço é classificado como curto quando:

`core_duration_minutes <= short_booking_threshold_minutes`

A classificação usa a duração contratada CORE.

PREP, POST e buffer não transformam um serviço curto em longo.

### 6.1 Regra de posição

Uma reserva curta só pode ser ofertada quando estiver:

1. encostada na borda inicial do bloco; ou
2. encostada na borda final do bloco; ou
3. adjacente a uma ocupação existente, respeitando a ocupação efetiva de cada reserva.

Ela **não** pode nascer no meio de um espaço vazio contínuo quando nenhuma dessas condições for verdadeira.

### 6.2 Definição matemática de borda inicial

Para um candidato simples sem PREP anterior:

`candidate.core_start_at = block.start_at`

Se o serviço possui PREP explicitamente configurado que ocupa o mesmo recurso físico, a validação de capacidade continua considerando a fase completa, mas a classificação de posição comercial usa o início CORE salvo regra específica do serviço.

### 6.3 Definição matemática de borda final

Como o buffer é apenas posterior, a borda final considera a ocupação efetiva do recurso:

`candidate.studio_occupied_end_at = block.end_at`

Exemplo — TARDE 13h30–18h30, locação de 2h + 30 min de buffer:

- candidato 16h00–18h00;
- buffer 18h00–18h30;
- `occupied_end_at = 18h30`;
- candidato válido na borda final.

Um candidato 16h30–18h30 teria buffer até 19h00 e **não** é borda final da TARDE.

Ele só poderá existir se alguma outra regra/janela operacional independente o tornar válido; não recebe validade pela Regra 2 como borda da TARDE.

### 6.4 Definição matemática de adjacência

Como o buffer existe somente após cada reserva, não há dois buffers entre reservas consecutivas.

**Candidato após uma reserva existente:**

`candidate.core_start_at = existing.occupied_end_at`

Exemplo:

- existente: 13h00–15h00;
- buffer existente: 15h00–15h30;
- próxima reserva pode iniciar às 15h30.

**Candidato antes de uma reserva existente:**

`candidate.occupied_end_at = existing.core_start_at`

Exemplo:

- reserva existente começa 16h00;
- candidato curto termina seu CORE às 15h30;
- buffer do candidato ocupa 15h30–16h00;
- `candidate.occupied_end_at = 16h00`;
- não existe intervalo desperdiçado nem buffer duplicado.

### 6.5 Serviços aos quais se aplica

Aplica-se hoje às locações com CORE de até 2h30 e pode ser aplicado a outros serviços por configuração.

Locações de 4h e diária de 8h não são classificadas como curtas e não precisam satisfazer borda/adjacência da Regra 2.

Isso não significa que possam ignorar disponibilidade, recursos ou buffers; apenas que não sofrem a restrição anti-fragmentação de reservas curtas.

---

## 7. Regra 3 — interseção de disponibilidade por recurso e fase

Um slot só pode ser ofertado quando todas as necessidades reais do serviço couberem simultaneamente.

A avaliação deve ser feita por **recurso e fase**, e não aplicando um único intervalo expandido indiscriminadamente a todos os participantes.

Devem ser consideradas:

- disponibilidade do recurso físico ESTÚDIO;
- disponibilidade do profissional executor;
- disponibilidade de recursos adicionais;
- disponibilidade de profissionais adicionais;
- PREP;
- CORE;
- POST;
- buffer operacional do recurso físico;
- disponibilidade de extras selecionados.

### 7.1 Exemplo Sabrina + maquiagem

Exemplo conceitual:

- PREP maquiagem: 07h30 até o horário configurado de término;
- CORE do ensaio: conforme horário contratado/configurado;
- POST buffer do estúdio: 30 minutos após o CORE.

O recurso maquiadora é necessário apenas durante sua fase.

A profissional Sabrina é necessária apenas durante as fases em que sua presença estiver configurada.

O ESTÚDIO pode estar ocupado por PREP + CORE + POST quando essas fases exigirem o recurso físico.

A implementação não deve bloquear automaticamente todos os recursos durante a união total de todas as fases se um recurso não participa de determinada fase.

### 7.2 Extra como condição para fase

Uma fase adicional só existe quando o extra correspondente foi realmente selecionado.

Exemplo:

`makeup_selected = false` → não existe PREP de maquiagem às 07h30.

`makeup_selected = true` → a fase PREP entra no cálculo antes da oferta dos slots.

Isso mantém a jornada já definida: extras que afetam duração/recursos entram no cálculo antes da seleção final de data e horário.

---

## 8. Ensaios da Fê em bloco fragmentado

Quando o bloco está completamente livre, o serviço da Fê segue seus horários de início configurados.

Quando já existe ocupação no bloco, o motor pode ofertar um ensaio da Fê adjacente à ocupação existente quando:

- o CORE cabe no resíduo;
- o buffer posterior do estúdio cabe;
- a profissional está disponível;
- o ESTÚDIO está disponível;
- recursos/extras adicionais estão disponíveis;
- nenhuma constraint autoritativa de ocupação é violada.

Na primeira versão, o motor **não protege o resíduo restante após o encaixe**.

Se um resíduo pequeno puder ser vendido legitimamente, deve ser vendido.

Não haverá simulação combinatória para tentar descobrir se outra composição futura seria mais lucrativa.

---

## 9. Locações longas

Locações de 4h e diária de 8h não estão sujeitas à Regra 2.

A oferta continua determinada por:

- janela operacional;
- disponibilidade do ESTÚDIO;
- fases/buffer;
- recursos adicionais;
- regras específicas do serviço.

Este ADR **não cria âncoras fixas obrigatórias para locação de 4h**.

Horários como 08h00 e 09h00 podem coexistir quando ambos forem válidos. Da mesma forma, 13h30 e 14h00 podem coexistir quando couberem segundo o contrato do motor.

A auditoria deve verificar que nenhuma nova regra anti-fragmentação passa a bloquear uma locação longa apenas para preservar outra locação longa hipotética.

---

## 10. Hold de checkout — invariantes

Este ADR **não altera o fluxo de hold**.

A geração de slots é uma pré-seleção de candidatos.

A criação do hold continua sendo a autoridade final sobre concorrência e ocupação.

Invariantes:

1. o slot precisa ser revalidado no momento do hold;
2. constraint/exclusão de ocupação continua autoritativa;
3. duas pessoas concorrendo pelo mesmo recurso não podem obter holds incompatíveis;
4. um hold vencido não pode bloquear disponibilidade depois de `expires_at`;
5. a duração do hold continua definida pela configuração vigente do serviço/operação, fora do escopo decisório deste ADR.

A auditoria deve verificar especificamente se a consulta pública ignora/expira holds cujo `expires_at <= now()` antes de concluir que o slot está indisponível.

---

## 11. O que foi deliberadamente descartado

### 11.1 Liberação por antecedência

Não haverá regra do tipo:

- proteger horários com mais de 7 dias;
- liberar horários curtos perto da data;
- alterar disponibilidade apenas porque o tempo passou.

Motivos:

- aumenta complexidade;
- cria disponibilidade temporalmente variável sem mudança de ocupação;
- dificulta explicação para cliente/equipe;
- as regras de composição já tratam a fragmentação por construção.

### 11.2 Simulação combinatória de fragmentação

Não será calculado o valor de todas as combinações futuras possíveis de uso do resíduo.

A V1 não executará otimização econômica da agenda.

### 11.3 Prioridade entre serviços

Não haverá tabela do tipo:

`Sabrina > locação 4h > Fê > locação 2h`.

A elegibilidade é definida por regras objetivas de ocupação/composição.

### 11.4 Âncoras fixas obrigatórias para locação longa

A V1 não obriga toda locação de 4h a começar somente em um único horário predeterminado se outros inícios couberem legitimamente.

---

## 12. Consequências

### Positivas

- reduz fragmentação por construção;
- mantém comportamento previsível enquanto ocupações/configurações não mudarem;
- evita previsão de demanda;
- evita prioridade comercial opaca;
- evita algoritmo combinatório no caminho crítico público;
- mantém a validação final de hold como autoridade;
- modela corretamente duração contratada separada de tempo operacional de reset;
- permite que extras afetem apenas os recursos/fases que realmente utilizam.

### Negativas

- uma reserva pequena pode tornar Sabrina inelegível naquele bloco inteiro, mesmo ocupando pouco tempo;
- vender uma reserva curta na borda pode eliminar uma futura locação longa;
- a regra otimiza composição física simples, não maximização de receita;
- a semântica de `requires_empty_block` precisa ser compreendida pela operação para não ser confundida com bloqueio artificial do bloco inteiro após a reserva.

### Riscos

- `short_booking_threshold_minutes = 150` pode precisar de ajuste após dados reais;
- configuração incorreta de PREP/CORE/POST pode criar falsa disponibilidade;
- buffer posterior aplicado duas vezes produziria ociosidade artificial;
- ignorar o buffer na borda final produziria sobreposição com o próximo bloco;
- uma implementação que trate todos os recursos com o mesmo `occupied_range` pode bloquear profissionais sem necessidade;
- holds expirados não limpos/ignorados podem gerar falso indisponível.

---

## 13. Configurações propostas

### Por recurso

- blocos de composição;
- `short_booking_threshold_minutes`;
- `post_buffer_minutes`;
- janela operacional.

### Por serviço

- `requires_empty_block`;
- duração CORE;
- horários fixos de início, quando aplicável;
- fases PREP/CORE/POST;
- recursos exigidos por fase;
- profissionais exigidos por fase.

### Por extra

- ativação de fase PREP/POST;
- delta de duração;
- recursos adicionais;
- profissional adicional;
- regra de horário excepcional quando aplicável, como maquiagem às 07h30.

---

## 14. Gate de implementação

Esta alteração deve possuir gate próprio e isolado.

Não combinar no mesmo PR com:

- Google Calendar;
- Kommo;
- Mercado Pago;
- mudança de state machine financeira;
- mudança de cancelamento/remarcação;
- refatorações extensas sem relação direta.

Sequência mínima:

1. ADR auditado e aprovado;
2. contrato de configuração;
3. testes de unidade/pgTAP das regras;
4. alteração do gerador de slots;
5. validação de hold sem regressão;
6. testes de concorrência;
7. teste de jornada pública;
8. somente então merge na branch autoritativa.

---

## 15. Casos de teste obrigatórios

1. Bloco vazio oferta Sabrina nos horários configurados, Fê nos horários configurados e locações válidas.
2. Qualquer ocupação incompatível no bloco remove Sabrina da oferta naquele período.
3. `requires_empty_block` é revalidado no momento do hold, não apenas na listagem.
4. Após Sabrina ser criada, somente fases/recursos efetivos + buffer ficam ocupados, se a semântica proposta da seção 5.2 for aprovada.
5. Locação CORE de 2h não é ofertada no meio de bloco vazio.
6. Locação CORE de 2h é ofertada na borda inicial.
7. Locação CORE de 2h é ofertada na borda final apenas quando `occupied_end_at = block.end_at`.
8. Locação CORE de 2h é ofertada após reserva existente quando `candidate.core_start_at = existing.occupied_end_at`.
9. Locação curta anterior a reserva existente só é ofertada quando `candidate.occupied_end_at = existing.core_start_at`.
10. Não há buffer duplicado entre duas reservas consecutivas.
11. Locação de 4h pode ser ofertada às 08h00 e às 09h00 quando ambas forem válidas.
12. Locação de 4h pode ser ofertada às 13h30 e às 14h00 quando ambas forem válidas.
13. Ensaio Fê é ofertado em resíduo adjacente válido.
14. Encaixe que ultrapassa disponibilidade da Fê não é ofertado.
15. Pausa/indisponibilidade da profissional elimina somente os slots que a intersectam.
16. Sabrina sem maquiagem não cria PREP às 07h30.
17. Sabrina com maquiagem pode criar PREP às 07h30 sem abrir slots públicos gerais antes das 08h00.
18. Extra de maquiagem indisponível remove apenas os slots que dependem da maquiadora/fase correspondente.
19. Buffer de 30 minutos ocupa o ESTÚDIO após CORE, mas não bloqueia automaticamente profissional que não participa do buffer.
20. Serviço com mais de um profissional é avaliado por profissional.
21. Recurso adicional exigido por extra é validado apenas nas fases em que é necessário.
22. Slot ofertado continua válido na criação do hold quando nada mudou.
23. Concorrência simultânea continua resultando em no máximo um hold incompatível vencedor.
24. Hold com `expires_at <= now()` não mantém slot indisponível.
25. NOTURNO é 19h00–22h00 e a transição 18h30–19h00 não é tratada como parte da TARDE nem do NOTURNO.
26. Reserva curta não recebe validade de borda da TARDE se seu buffer posterior ultrapassar 18h30.
27. A classificação curta usa CORE <= 150 minutos, não CORE + buffer.
28. Alterar `short_booking_threshold_minutes` muda a classificação sem alterar duração contratada.

---

## 16. Decisões comerciais mantidas em aberto

Não bloqueiam a auditoria arquitetural.

### 16.1 Duração mínima aos fins de semana

Sábado permanece sem duração mínima por decisão comercial atual. Reavaliar com dados reais de ocupação e custo operacional.

### 16.2 Escada de desconto por duração

Mantida por competitividade. Não faz parte deste ADR.

### 16.3 Diária de 8h

Permanece válida apesar do impacto sobre a agenda por ser uma modalidade rara. Monitorar frequência.

---

## 17. Métricas após implementação

- blocos em que Sabrina deixou de ser ofertada por ocupação prévia;
- frequência de encaixe da Fê em resíduos;
- ocupação média por MANHÃ, TARDE e NOTURNO;
- receita por bloco e composição de serviços;
- locações curtas recusadas por posição inválida;
- distribuição dos horários efetivamente vendidos para locações de 1h/2h/4h;
- quantidade de resíduos vendidos;
- quantidade de slots recusados por buffer;
- ocorrências de hold expirado ainda observado como indisponível, que devem ser zero.

---

## 18. Checklist específico para auditoria

O auditor deve responder explicitamente:

1. A distinção CORE x ocupação efetiva está consistente com o modelo atual?
2. O buffer posterior de 30 min está representado uma única vez em todas as paths?
3. A definição de borda/adjacência é determinística e sem ambiguidade?
4. `requires_empty_block` deve ser apenas condição de admissão ou também bloquear artificialmente todo o bloco após a reserva?
5. O gerador atual consegue avaliar PREP/CORE/POST por recurso sem regressão estrutural?
6. A exceção 07h30 para maquiagem pode ser modelada sem ampliar a janela pública geral?
7. Os blocos 08–13, 13h30–18h30 e 19–22 são compatíveis com as regras atuais de availability?
8. A Regra 2 deve valer apenas para locações ou ser uma capacidade configurável reutilizável por serviço?
9. O limite de 150 minutos deve estar no recurso, no serviço ou em política de composição separada?
10. A listagem pública elimina corretamente holds expirados antes de decidir indisponibilidade?
11. A criação do hold revalida todas as novas regras ou apenas a ausência de sobreposição física?
12. Há risco de TOCTOU entre listagem e hold que exija nova verificação transacional?
13. A Regra 1 pode ser validada transacionalmente sem introduzir lock excessivo?
14. A Regra 2 pode ser calculada sem consulta combinatória e sem degradação relevante da tela pública?
15. Algum estado de `resource_allocations` atual precisa ser redefinido para estas regras?
16. Há conflito com Google Calendar/external blocks existentes?
17. Os casos de teste listados cobrem bordas, DST/timezone, virada de bloco e concorrência suficiente?
18. O ADR altera alguma regra financeira ou de duração percebida pelo cliente inadvertidamente?

---

## 19. Critério para aprovação

Este ADR só pode mudar de **PROPOSTO PARA AUDITORIA** para **ACEITO** quando:

- todos os itens críticos do checklist tiverem resposta;
- ambiguidades de semântica forem resolvidas no próprio documento;
- não houver conflito com o modelo autoritativo de recursos/holds;
- houver plano de testes que cubra listagem e criação concorrente de hold;
- a implementação puder ser feita em gate próprio sem misturar integrações externas.

Até lá, **nenhuma alteração no motor de slots deve ser executada com base neste ADR**.
