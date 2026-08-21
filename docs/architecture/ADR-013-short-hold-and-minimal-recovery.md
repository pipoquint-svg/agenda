# ADR-013 — Hold curto no preenchimento e recuperação mínima de checkout

Status: Accepted

## Contexto

A recuperação avançada de carrinho continua fora do escopo V1. Porém, o sistema já possui `checkout_holds`, outbox e canal transacional por WhatsApp. Existe portanto uma recuperação mínima de alto valor e baixo custo: quando um hold expira, avisar o cliente e oferecer um link para retomar a seleção.

Ao mesmo tempo, o maior risco de conversão do fluxo público acontece depois que o cliente escolhe um horário e passa a preencher seus dados. Se o slot continuar apenas como disponibilidade visual nesse intervalo, outro cliente pode ocupá-lo antes da conclusão.

## Decisão

1. `create_checkout_hold()` deve ser chamado imediatamente quando o usuário confirma a escolha do horário.
2. O hold bloqueia todos os recursos necessários durante o preenchimento restante.
3. O default operacional permanece em 10 minutos, com override por serviço.
4. Quando o telefone for informado durante um hold ativo, ele pode ser associado à recuperação daquele hold.
5. `expire_due_checkout_holds()` sempre libera o recurso primeiro e, se houver contato de recuperação válido, cria um único job `CHECKOUT_HOLD_EXPIRED_RECOVERY`.
6. A mensagem usa o template lógico `checkout_hold_expired_recovery` e contém link de retomada.
7. O link de retomada restaura apenas contexto comercial sanitizado: serviço, profissional, extras, pessoas e horário anterior.
8. O link nunca ressuscita o hold nem reserva novamente o horário expirado. A disponibilidade é recalculada; o horário anterior só pode ser selecionado novamente se continuar livre.
9. Recuperação avançada, automações em sequência, múltiplos follow-ups e scoring de abandono permanecem fora do escopo V1.

## Segurança e privacidade

- token de retomada é opaco e de alta entropia;
- o endpoint de retomada não devolve telefone, nome ou notas internas;
- o token não concede capacidade de reservar ou alterar uma reserva confirmada;
- mensagem é idempotente por hold;
- credenciais da Meta ficam somente em secrets de ambiente.

## Consequência

A Agenda protege o slot justamente no trecho de maior fricção do checkout e transforma a mensagem de expiração em recuperação comercial, sem reabrir o escopo de carrinho abandonado avançado.
