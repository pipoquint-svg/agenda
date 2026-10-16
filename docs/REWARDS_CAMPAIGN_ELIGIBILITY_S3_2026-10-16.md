# BlackSheep Rewards — S3 elegibilidade (2026-10-16)

S3 adiciona somente `service_evaluate_marketing_campaign_eligibility(campaign_id, source_appointment_id)`. A RPC privada, `SECURITY DEFINER` e disponível exclusivamente ao `service_role` retorna uma decisão determinística; não cria cupom, issuance, auditoria, mensagem, job, reserva, checkout ou campanha.

Uma decisão `ELIGIBLE` exige campanha `ACTIVE` no tenant de bootstrap `blacksheep`, versão ativa publicada com o gatilho de locação, janela temporal válida, cliente canônico e appointment `COMPLETED` + `PAID`. A fonte é reconhecida pelo snapshot histórico de escopo `BLACKSHEEP` e tipo `LOCACAO`, não pelo catálogo atual. Appointments legados sem snapshot retornam `BLOCKED`.

Os snapshots são capturados quando o appointment é criado ou muda de serviço e são imutáveis quando o serviço não muda. Isso impede que uma reclassificação posterior do catálogo, ou uma escrita direta nos snapshots, reescreva a elegibilidade histórica. A recorrência bloqueia qualquer `appointment_discounts` quando a versão não permite recorrência. Uma issuance já vinculada à mesma fonte também bloqueia a decisão.

Verificação: `supabase/tests/database/172_marketing_campaign_eligibility_evaluator.test.sql` contém 18 asserções para ACL, happy path, status, quitação, tenant bridge, janela, recorrência, anti-duplicação e integridade do snapshot. O reset local não pôde iniciar porque não há stack Supabase local ativa; a validação executável é a CI canônica da PR.

S4 continua responsável pela emissão transacional e idempotente de cupom. S5 continua responsável pela aplicação no checkout.
