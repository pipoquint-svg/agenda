# A2.1 — Remarcação de locação não reduz blocos

## Regra comercial

Uma remarcação de locação pode incluir mais blocos, nunca menos. Para ensaio, a remarcação não troca de serviço.

## Evidência da V1 atual

O contrato atual de `service_admin_create_reschedule_hold` recebe somente reserva, novo início, instante da solicitação, origem da alteração e administrador. Ele não recebe nova duração nem nova quantidade de blocos.

Ao criar o hold protegido, a função reutiliza explicitamente da reserva existente:

- `service_id`;
- `service_employee_id`;
- `duration_blocks`;
- extras;
- quantidade de pessoas.

Portanto o caminho V1 atualmente disponível é uma remarcação de horário com **igualdade de blocos**. Não existe entrada no contrato atual que permita ao chamador reduzir a quantidade de blocos. `service_admin_apply_reschedule` promove os valores do hold protegido de volta para a mesma reserva.

O pgTAP `029_admin_reschedule_holds.test.sql` passa a provar explicitamente os dois lados da operação:

1. o hold de remarcação recebe exatamente `appointment.duration_blocks`;
2. depois da aplicação, a reserva continua com exatamente a quantidade original de blocos.

## Veredito

A regra **"nunca menos"** está estruturalmente satisfeita no contrato V1 atual por preservação exata da quantidade de blocos, e agora possui prova regressiva explícita.

A capacidade de **aumentar** blocos não existe nesse mesmo contrato hoje. Implementá-la exigirá uma extensão explícita do fluxo; quando isso ocorrer, a nova entrada deverá preservar obrigatoriamente o piso `new_duration_blocks >= original_duration_blocks`. Essa capacidade não é criada neste fechamento de pré-produção porque não é necessária para corrigir uma redução silenciosa existente e alteraria o contrato funcional atual.

## Não muda

- nenhum contrato HTTP/frontend;
- nenhuma migration ou schema;
- nenhum preço, política ou cálculo financeiro;
- nenhum comportamento de Google, Kommo ou Mercado Pago;
- nenhum dado de sandbox ou produção.
