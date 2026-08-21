# ADR-014 — Amelia permanece autoridade até a última reserva; Agenda importa apenas histórico

## Status

ACEITO

## Contexto

As reservas criadas no Amelia já estão sincronizadas com o Google Calendar. O Amelia permanecerá ativo e operacional até a última reserva originada nele ser cumprida.

Transformar essas reservas em `appointments` da BlackSheep Agenda criaria duas fontes operacionais para a mesma obrigação e aumentaria o risco de:

- duplicar eventos Google;
- duplicar bloqueios de agenda;
- permitir alteração no sistema errado;
- disparar mensagens/cobranças indevidas;
- inferir incorretamente valor pago/saldo a partir do export legado.

## Decisão

Reservas Amelia entram na BlackSheep Agenda apenas como histórico em `legacy_amelia_bookings`.

Para todo registro legado:

```text
source_system = AMELIA
operational_authority = AMELIA
record_mode = HISTORY_ONLY
```

A importação nunca cria automaticamente:

- `appointments`;
- `resource_allocations`;
- `payment_transactions`;
- `integration_jobs`;
- eventos Google gerenciados pela Agenda;
- mensagens de confirmação/cobrança.

## Google Calendar

Enquanto reservas Amelia futuras existirem, seus eventos Google continuam chegando ao sync como eventos externos e geram os bloqueios externos normais quando qualificáveis.

A BlackSheep Agenda não adota nem transforma esses eventos em eventos gerenciados.

Assim:

```text
Amelia = autoridade da reserva antiga
Google = bloqueio externo correspondente
BlackSheep Agenda = histórico somente leitura
```

## Alterações/cancelamentos no período de convivência

Qualquer alteração de reserva originada no Amelia continua sendo feita no Amelia.

Um novo export pode atualizar o snapshot histórico pelo mesmo `amelia_booking_id`. Esse reimport é idempotente e aumenta `import_revision`, sem qualquer efeito operacional.

## CPF/CNPJ ausente

O export Amelia pode não conter CPF/CNPJ.

Regra:

```text
cpf_cnpj = NULL
```

Nunca fabricar, inferir ou bloquear a importação por ausência desse dado.

Na próxima reserva nativa do cliente na BlackSheep Agenda, o fluxo deve solicitar o CPF/CNPJ quando a configuração do atendimento exigir e completar o cadastro.

## Financeiro legado

Campos como `Preço` do export Amelia são preservados como fonte histórica (`amelia_price_amount`) e não são tratados automaticamente como:

- valor contratado;
- valor pago;
- sinal;
- saldo.

A semântica financeira do legado não alimenta a máquina financeira nativa sem reconciliação explícita.

## Segurança

Administradores podem consultar o histórico, mas não inserir/editar/excluir diretamente pela UI.

Somente o importador de sistema (`service_role`) pode criar ou atualizar snapshots legados.

## Consequência para go-live

O novo sistema pode começar a receber novas reservas enquanto o Amelia cumpre as reservas antigas.

O Amelia é desligado para novos bookings na virada pública, mas permanece disponível para gestão das reservas antigas até a última delas ser concluída.

Depois disso, o Amelia deixa de participar da operação e permanece apenas como referência histórica externa, enquanto os snapshots necessários já estão disponíveis na Agenda.
