# Rollback I-09

Mudança de schema é expand-only. Se houver regressão antes de produção, os novos constraint triggers podem ser desabilitados e as funções administrativas/snapshot podem ser restauradas por migration aditiva posterior. Nenhuma tabela/coluna existente é removida.

A desativação das duas fixtures é reversível somente após atribuir política explícita; não reativar fixture sem política.
