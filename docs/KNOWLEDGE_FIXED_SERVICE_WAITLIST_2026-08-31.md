# Lista de espera para serviços FIXED — 2026-08-31

## Fronteira funcional

A lista de espera é um fallback manual **exclusivo de serviços com `duration_mode = 'FIXED'`** quando uma busca pública de horários foi concluída com sucesso e retornou zero opções.

- Não se aplica a serviços `BLOCKS`.
- Não altera nem participa do motor de disponibilidade.
- Não altera precificação, holds, checkout ou pagamento.
- A data pesquisada não é uma preferência persistida: a espera é por serviço, não por data.
- Não existe aviso automático ao cliente quando surge vaga. A equipe faz o contato manualmente.

## Dados e duplicidade

Cada inscrição registra nome, e-mail, WhatsApp, serviço e `created_at`. E-mail e WhatsApp são normalizados e validados. A mesma pessoa não pode se inscrever duas vezes no mesmo serviço usando o mesmo e-mail ou WhatsApp, mas pode entrar em listas de serviços FIXED diferentes.

Quando possível, a inscrição é associada a um cliente existente por e-mail ou telefone. A listagem administrativa também faz correspondência tardia para reconhecer clientes cadastrados depois da inscrição.

## Notificação interna

Cada nova inscrição usa o evento `WAITLIST_SIGNUP_TEAM` na plataforma unificada de notificações. O envio passa pelo resolvedor de templates, renderer, remetente/provedor canônico e `notification_delivery_logs`. O evento legado `WAITLIST_AVAILABLE` não é usado por este fluxo.

A falha temporária do provedor de e-mail não invalida a inscrição; a evidência de entrega fica registrada como falha para acompanhamento operacional.

## Gestão e RBAC

Permissões dedicadas:

- `WAITLIST_VIEW`: visualizar e exportar a lista.
- `WAITLIST_MANAGE`: marcar uma inscrição como contatada.

`OPERATION` recebe ambas por padrão; `FINANCE` não recebe acesso por padrão. Alterações explícitas de permissão passam pelo mesmo fluxo de Equipe da Gestão.

A marcação de contato registra `contacted_at`, `contacted_by_admin_id` e audit log.

## Paginação e exportação

A API administrativa usa paginação keyset por `(created_at, id)`. Não existe teto global de registros. A exportação CSV percorre todas as páginas do filtro atual até `next_cursor = null`.

Todos os horários apresentados na Gestão usam `America/Sao_Paulo`.
