# I-09 — invariante na origem

Decisão autorizada: todo serviço ativo exige política própria.

Garantias implementadas neste PR:

1. criação administrativa de serviço gera rascunho inativo, preservando as assinaturas HTTP/RPC existentes;
2. ativação e reativação são verificadas por constraint trigger diferida;
3. remoção de política de serviço ativo é impedida por constraint trigger diferida;
4. serviço + política podem ser criados/ajustados atomicamente na mesma transação;
5. captura de snapshot falha explicitamente se, apesar das garantias anteriores, uma confirmação alcançar serviço sem política.

Nenhum fallback por operação/tipo é criado e nenhuma regra comercial é inferida.
