# Admin Read Models V1

Endpoint administrativo read-only para as áreas Financeiro, Pacotes, Auditoria, Equipe/permissões e Integrações.

- autenticação: Supabase Auth + `admin_users` ativo;
- autorização: permissão específica por `view`;
- sem mutação de negócio;
- sem exposição de secrets, provider payloads ou idempotency keys;
- Google é somente estado de gate nesta frente; nenhuma chamada ao provider é executada.
