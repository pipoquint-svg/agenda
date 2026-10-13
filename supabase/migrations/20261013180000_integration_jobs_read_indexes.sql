-- Leituras frequentes de integration_jobs faziam varredura completa (~57 mil linhas):
-- * alertas operacionais e visão de integrações filtram por intervalo de created_at
--   (produção: ~154 ms por chamada, >1.000 chamadas);
-- * a reconciliação do Mercado Pago filtra por entity_id (produção: ~108 ms, >800 chamadas).
-- Só colunas que não mudam após a inserção são indexadas: as atualizações de status
-- feitas pelos workers continuam elegíveis a HOT update.

create index if not exists integration_jobs_created_at_idx
  on public.integration_jobs (created_at);

create index if not exists integration_jobs_entity_id_idx
  on public.integration_jobs (entity_id);
