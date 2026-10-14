# BlackSheep Rewards — S1 fundação de campanhas (2026-10-14)

## Escopo aprovado

Fundação de dados **inativa** e isolada no backend Agenda. Nenhuma nova campanha é criada, ativada ou executada; nenhum cupom, mensagem, checkout, reserva, pagamento, Kommo ou Dracma é alterado por esta migration.

Base de implementação: S0.5 aplicado em produção; `coupons.discount_scope` e `appointment_discounts` permanecem como mecanismo único de descontos e consumo.

## Tabelas

- `marketing_campaigns`: catálogo por `tenant_id`, chave exclusiva por tenant, estado DRAFT/SCHEDULED/ACTIVE/PAUSED/ENDED/ARCHIVED, janela e identidade administrativa.
- `marketing_campaign_versions`: revisões append-only para `service_role`. Gatilho tipado, regra de desconto, escopo, validade, limites, renovação, exclusões, comunicação/segmentação JSONB.
- `marketing_campaign_issuances`: futuro vínculo de cupom emitido à versão exata, cliente, origem e chave idempotente única. S1 **não emite** cupons.
- `marketing_campaign_audit_events`: envelope append-only para eventos de administração; S2 deve fazer as escritas auditadas em uma transação ou por RPC protegida. S1 não executa mudanças administrativas.

A tripla `(campaign_version_id,campaign_id,tenant_id)` exige correspondência à versão e ao tenant corretos. O índice `unique(campaign_id,idempotency_key)` impede emitir duas vezes para a mesma identidade de evento por campanha; a restrição `unique(coupon_id)` impede vincular um cupom a múltiplas emissões.

## Segurança

RLS habilitada e sem políticas em todas as quatro tabelas; `PUBLIC`, `anon` e `authenticated` não recebem grants de tabelas. `service_role` recebe SELECT/INSERT nas quatro e UPDATE **apenas** no catálogo de campanhas; não recebe DELETE. A imutabilidade de versões/issuances/auditoria é uma garantia de autorização para o runtime, não uma afirmação de que o owner do banco não pode reescrever dados.

**Pendência de S2:** nenhuma API de edição é criada por S1. O S2 deverá implementar autorização OWNER/ADMIN, gravação obrigatória em `marketing_campaign_audit_events`, transições de estado e publicação só com versão aprovada. Não expor DML diretamente no browser.

## Regras da campanha inicial (não ativada no S1)

- Gatilho `RENTAL_COMPLETED_FINANCIALLY_CLEARED`: locação concluída operacionalmente e financeiramente regularizada. Não significa apenas horário passado, reserva confirmada ou pagamento parcial.
- 20% de desconto, `SERVICE_ONLY`, um uso por código, exclusivamente pelo cliente, sem extras e sem desconto sobre pacote de horas.
- `BOOKING_CONFIRMATION`, `validity_days=30`: **confirmar a nova reserva dentro de 30 dias; o aluguel pode ocorrer sem restrição adicional de data**.
- `recurring_after_discounted_rental=true`: a locação que usou um cupom pode originar o próximo, após conclusão e quitação. Não há teto de ciclos.
- Canais, opt-in/out e templates futuros serão configuráveis e sujeitos à política do provedor; S1 apenas armazena `message_rules`.

S5 deve adicionar uma verificação de validade para cupons vinculados à campanha pela **data de confirmação da reserva**. As rotas antigas continuam avaliando a data do aluguel para cupons legados até que essa regra seja explicitamente implementada; a migration S1 não modifica cálculos.

## Gates

- Migration: `supabase/migrations/20261014230000_marketing_campaign_foundation.sql`.
- pgTAP: `supabase/tests/database/170_marketing_campaign_foundation.test.sql`, 38 assertions com dados temporários e rollback.
- RLS baseline: quatro tabelas privadas adicionais no overlay.
- Item 2A: migration S1 estacionada/restaurada no teste do baseline histórico.
- ACL Item 2C: nenhum RPC ou função pública nova; os contadores de funções permanecem intactos.

## Aceitação e limites

Concluir CI canônico (pgTAP, ACL, RLS, Item 2A, reconstrução) e revisão adversarial antes de recomendar merge. CI não comprova autorização de mensagens, regra de faturamento, status COMPLETED, habilitação de campanha ou checkout remoto: todos fora do S1.

**Não realizar merge, deploy nem ativar campanhas** durante este slice. O S2 implementará a interface/autorização de administração. S3-S6 incorporarão elegibilidade, gatilhos, emissão e checkout/entrega. O Claude deve atuar apenas como **revisor adversarial**, sem editar o repositório.
