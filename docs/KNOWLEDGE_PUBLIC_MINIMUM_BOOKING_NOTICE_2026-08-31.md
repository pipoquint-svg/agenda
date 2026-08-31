# Knowledge — antecedência mínima pública de reserva

Data: 2026-08-31

## Decisão

A antecedência mínima do fluxo público é uma política de borda e não uma regra do motor interno de disponibilidade.

A fonte canônica para essa política é:

`services.public_minimum_booking_notice_hours`

Ela é aplicada somente pelos wrappers públicos de disponibilidade:

- `public_list_available_slots`
- `public_list_available_slots_duration`
- `public_list_available_slots_minutes`

As funções internas de disponibilidade não devem consultar esse campo.

## Dois campos parecidos, semânticas diferentes

| Campo | Status | Unidade | Onde atua | Uso correto |
| --- | --- | --- | --- | --- |
| `minimum_booking_notice_minutes` | legado | minutos | motor/core de disponibilidade; pode afetar qualquer chamador que chegue às funções internas | manter em `0`; não usar para antecedência exclusiva do site público |
| `public_minimum_booking_notice_hours` | canônico para público | horas | somente os três wrappers públicos de disponibilidade | usar para configurar a antecedência mínima apresentada ao cliente no fluxo público |

### `minimum_booking_notice_minutes`

Este campo é legado. Ele está acoplado ao core e, por isso, sua alteração pode alcançar chamadas administrativas ou internas além do checkout público.

Na auditoria imediatamente anterior a esta entrega, os três serviços existentes em produção estavam com o valor `0`.

Regra operacional enquanto o campo existir:

- manter em `0`;
- não usá-lo para configurar a antecedência pública;
- não introduzir novos consumidores desse campo;
- qualquer mudança de sua semântica exige uma entrega separada.

### `public_minimum_booking_notice_hours`

Este é o campo correto para antecedência pública.

Regras:

- `integer not null default 0`;
- valor não negativo;
- `0` preserva o comportamento público anterior;
- comparação feita diretamente entre valores `timestamptz`;
- nenhuma comparação textual;
- nenhum offset fixo como `-03:00`;
- fronteira inclusiva: `slot_start_at >= now() + make_interval(hours => public_minimum_booking_notice_hours)`;
- não altera geração de candidatos, cadência, regras de jornada, recursos físicos, conflitos, holds, duração, buffers ou gate do Google Calendar.

## Por que o campo legado não foi reaproveitado

Reaproveitar `minimum_booking_notice_minutes` para a política pública misturaria duas responsabilidades: uma regra do core e uma regra específica da borda pública. Isso ampliaria o efeito de uma configuração comercial do site para chamadas administrativas e internas.

A decisão desta entrega é manter o motor intacto e aplicar a política somente nos wrappers públicos.

## O campo legado pode ser aposentado depois?

Sim, mas a aposentadoria deve ser uma iniciativa separada e não faz parte desta entrega.

Antes de removê-lo é necessário:

1. inventariar todas as referências SQL, RPC, Edge Functions, frontend, testes e integrações ao `minimum_booking_notice_minutes`;
2. confirmar que o valor permanece `0` em todos os ambientes e em todos os serviços;
3. demonstrar que nenhum fluxo administrativo, interno ou legado depende semanticamente desse filtro;
4. criar testes de compatibilidade e executar rebuild limpo do banco;
5. retirar, em migration dedicada, os checks/leituras do campo nas funções internas que ainda o consumirem;
6. validar disponibilidade pública, administrativa, duração variável, conflitos, recursos, holds e integrações após essa retirada;
7. somente em uma migration posterior, quando não houver mais leitores/escritores, remover a coluna.

Não executar esses passos de aposentadoria junto com alterações de agenda, preço ou checkout. O objetivo é evitar novamente dois controles de tempo parcialmente sobrepostos e difíceis de rastrear.

## Guardas de regressão desta entrega

A suíte específica deve provar, no mínimo:

1. valor público `0` preserva a disponibilidade anterior;
2. slot anterior ao cutoff é ocultado no público;
3. slot exatamente no cutoff é aceito;
4. slot posterior ao cutoff é aceito;
5. os três wrappers públicos possuem o filtro nativo em `timestamptz`, sem texto e sem offset fixo;
6. as duas funções internas de disponibilidade mantêm exatamente as definições do baseline aprovado.
