# Hold tardio no checkout e sessão administrativa compartilhada — 2026-10-12

## Causa original do hold antecipado

As jornadas públicas criavam o `checkout_hold` (10 min) no clique do horário:

- BlackSheep (`black-sheep` `BookingJourneyV1.chooseSlot`) — e o token ficava só em memória, então um refresh deixava um hold órfão bloqueando o próprio horário por até 10 min;
- Sabrina/Natal (`web/src/SabrinaBookingJourney.tsx` `protectSlotAndContinue`);
- página por duração (`web/src/BookingPageDuration.tsx` `protectSlot`).

`web/src/BookingPage.tsx` também cria hold no clique, mas não é importado por nenhuma rota/embed (código morto) e não foi alterado.

## Novo contrato

- Serviço, duração, data/horário, extras e pessoas são estado de navegação: nenhum hold, nenhuma alocação, nenhum contador.
- O hold é criado uma única vez ao entrar em "Seus dados", com a seleção completa (extras e pessoas), pelo motor existente (`booking-hold` → `public_create_checkout_hold_tracked_minutes`). A exclusão GiST continua sendo a autoridade de concorrência; o buffer pós-serviço continua no período protegido (08:30 + 4h → ocupação até 13:00).
- `expires_at` vem do servidor; o navegador só exibe a contagem. Refresh recupera o mesmo hold via `sessionStorage` (token + seleção, nunca dados pessoais) e revalida em `CONTEXT`; o prazo nunca é renovado.
- Trocar a seleção protegida cria o novo hold e só então libera o anterior (`booking-checkout` `RELEASE`). Se o conflito for com o próprio hold anterior, ele é liberado e a criação é tentada uma única vez.
- Expiração durante "Seus dados"/"Revisão" preserva os dados digitados e pede nova confirmação de disponibilidade.
- Holds administrativos de remarcação, de convites privados da lista de espera e a jornada de visita gratuita (que já cria o hold na entrada dos dados) não mudam.

## Backend

Migração `20261012120000_public_checkout_hold_release.sql`: `service_public_release_checkout_hold(text)`, SECURITY DEFINER, executável só por `service_role`, idempotente, restrita a holds ACTIVE de booking page sem vínculo com remarcação ou lista de espera. Marca o hold `INVALIDATED`, alocações `RELEASED` e reservas de pacote `RELEASED`. Nenhuma tabela, preço, pagamento ou cupom muda.

`booking-checkout` ganhou a action `RELEASE`.

## Sessão administrativa

- `black-sheep`: `src/lib/gestaoAuthSession.ts` é a fonte única (um `onAuthStateChange`, sem `getSession`; `INITIAL_SESSION` entrega a sessão restaurada). O perfil (`access_profile`) é buscado em paralelo ao download do painel e deduplicado; 401 encerra a sessão local uma vez; 403 mostra acesso negado sem repetir. O layout aparece com skeleton; nenhum módulo protegido monta antes do perfil autorizado pelo backend.
- `agenda/web`: `web/src/adminSession.ts` mantém o contrato `getSession`/`onAuthStateChange` para os 15 módulos de gestão, com um único listener real.

Medição local (vitest, latências simuladas de 40 ms para sessão e 300 ms para perfil, 3 execuções cada, mesmo harness em `main` e na branch): shell ~146 ms → ~94 ms; conteúdo autorizado ~452 ms → ~356 ms; `getSession` 2 → 0; listeners 2 → 1; pedidos de perfil 1 → 1. Não há medição em produção.

## Testes

- pgTAP `166_late_checkout_hold_release.test.sql` (23 asserções): seleção sem hold, hold único com 10 min, buffer até 13:00, cliente concorrente rejeitado, `UPDATE_SELECTION` sem renovar prazo, release idempotente, token liberado/expirado rejeitado, expiração libera o horário, holds fora do contrato público recusados, ACL.
- `black-sheep`: testes de jornada T1–T8, T11–T13, T18 e de sessão T19–T26.
- E2E local (stack isolada + build de produção do `web`): duração BlackSheep e Sabrina — zero hold antes dos dados, um hold no duplo clique, 409 para o segundo cliente, refresh sem novo hold, troca de horário liberando o anterior, expiração e reconfirmação.
