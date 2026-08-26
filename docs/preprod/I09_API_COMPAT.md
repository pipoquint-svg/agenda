# I-09 — compatibilidade de API

As assinaturas de `service_admin_create_service_audited` e `service_admin_create_service_catalog_audited` permanecem idênticas. A única mudança operacional é que um novo serviço nasce inativo (rascunho), pois a decisão autorizada proíbe serviço ativo sem política. A ativação continua usando os endpoints existentes depois da política ser configurada.

Nenhum contrato consumido pelo frontend recebe campo removido/renomeado.
