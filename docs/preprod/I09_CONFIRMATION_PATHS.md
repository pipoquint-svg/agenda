# I-09 — caminhos que gravam/promovem `CONFIRMED`

Inventário do fechamento V1. Não altera comportamento.

| caminho | origem | `confirmed_at` | snapshot de política | veredito antes do hardening |
|---|---|---|---|---|
| `promote_checkout_hold` | checkout público / pacote / valor devido zero | sim quando confirma imediatamente | trigger `capture_current_appointment_change_policy_snapshot` | podia omitir snapshot se o serviço não tivesse política |
| `confirm_appointment_internal` | confirmação interna | sim | mesmo trigger | podia omitir snapshot se o serviço não tivesse política |
| Mercado Pago webhook → processamento do provider → `confirm_appointment_internal` | webhook de pagamento | sim | mesmo trigger | podia omitir snapshot se o serviço não tivesse política |
| pagamento manual → `confirm_appointment_internal` | admin financeiro | sim | mesmo trigger | podia omitir snapshot se o serviço não tivesse política |
| confirmação sem pagamento → `confirm_appointment_internal` | fluxo autorizado sem cobrança | sim | mesmo trigger | podia omitir snapshot se o serviço não tivesse política |
| `service_admin_confirm_pre_reservation` em modo `INVOICE` | pré-reserva administrativa | sim | mesmo trigger | podia omitir snapshot se o serviço não tivesse política |
| fixtures `TOKEN-EVIDENCE-1/2` | inserção sintética direta no banco | não | não | violações históricas conhecidas; não representam caminho comercial |

## Sequenciamento do hardening

Este PR fecha somente a garantia na origem: serviço ativo exige política própria e a política não pode ser removida enquanto o serviço permanecer ativo. O `RAISE EXCEPTION` explícito no trigger de snapshot será aplicado no PR seguinte do mesmo I-09, depois de adequar as fixtures transacionais dos testes ao novo invariante. Isso evita introduzir um modo de falha permanente em confirmação/pagamento enquanto os testes históricos ainda criam serviços sintéticos ativos sem política.

As duas fixtures históricas permanecem separadas da análise de caminhos de aplicação e a constraint de destino do #230 continua `NOT VALID` até o tratamento determinístico autorizado.
