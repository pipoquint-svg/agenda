# Knowledge — Âncora da grade de disponibilidade

**Status:** vigente desde 2026-08-30.

## Decisão arquitetural

A jornada é definida pelo par **funcionário + serviço**, representado por `service_employee_id`.

Para o serviço que está sendo agendado:

- cada faixa semanal ativa de `availability_rules` daquele `service_employee_id` gera sua própria série de candidatos;
- a âncora da série é o **início da própria faixa**;
- cada nova faixa reinicia a cadência de forma independente;
- uma exceção `OPEN` do mesmo `service_employee_id` gera sua própria série, ancorada no início da abertura excepcional;
- quando uma abertura `OPEN` se sobrepõe a uma faixa semanal e produz o mesmo início, o candidato é deduplicado;
- faixas de outro serviço, mesmo que atribuídas ao mesmo funcionário, não participam da grade do serviço consultado.

## Cadência

A cadência dos horários ofertados vem de `services.slot_interval_minutes`.

- valor padrão/fallback: **30 minutos**;
- valores permitidos: múltiplos de 30, de 30 a 480 minutos;
- `availability_rules.slot_interval_minutes` permanece no modelo por compatibilidade administrativa, mas **não comanda a grade de candidatos** quando o passo do serviço está disponível.

A jornada informa **quando o par funcionário + serviço pode atender**. O serviço informa **a duração e o passo**. Não existe uma terceira camada de faixa horária por serviço.

## Recursos físicos: somente filtro

A disponibilidade do espaço físico e de outros recursos obrigatórios **não gera série própria e nunca reancora a cadência**. Recursos atuam somente como filtro sobre os candidatos que já nasceram da jornada do `service_employee_id`.

Caso canônico de regressão:

1. Jornada do funcionário + serviço: `08:30–13:00`.
2. Passo do serviço: `90 min`.
3. Série gerada: `08:30, 10:00, 11:30`.
4. Espaço aberto `08:00–22:00`: os três candidatos sobrevivem.
5. Espaço aberto somente a partir de `09:00`: `08:30` é removido, mas `10:00` e `11:30` permanecem exatamente nos mesmos pontos.

Qualquer implementação que, no item 5, passe a oferecer `10:30` por causa da abertura do espaço às `09:00` está incorreta: o espaço filtrou e indevidamente reancorou a grade.

## Invariante de isolamento entre serviços

O mesmo funcionário pode ter serviços com jornadas diferentes.

Exemplo:

- Serviço A: faixas `08:30–13:00` e `14:00–20:00`;
- Serviço B: faixa `09:15–12:15`.

Ao consultar A, somente o `service_employee_id` de A pode originar candidatos. As faixas de B não podem alterar, ampliar, reduzir ou deslocar a grade de A, e vice-versa.

## Invariantes preservados

Esta decisão altera apenas a **origem da sequência de horários candidatos**. Permanecem sem mudança semântica:

- duração e duração contratada;
- buffers e cálculo de preço;
- trava de conflito;
- checkout holds e demais holds;
- critérios e disponibilidade de recursos;
- exceções `BLOCK`;
- gate de sincronização do Google;
- assinaturas e comportamento dos wrappers públicos.

O frontend não calcula a grade. Ele continua consumindo os resultados do backend.

## Regressão da Locação do estúdio

Com `services.slot_interval_minutes = 30` e as faixas atuais iniciando em horários alinhados a 30 minutos, a **Locação do estúdio mantém a mesma grade** que possuía antes da mudança de âncora.

Teste automático de referência: `supabase/tests/database/133_service_employee_window_anchor.test.sql`.
