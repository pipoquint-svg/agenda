-- Correção da liberação (20261021080000): dispatch_admin_id recebeu o id de login
-- (tenant_members.user_id = admin_users.auth_user_id), mas o Dracma vincula o
-- administrador pelo admin_users.id, que é o que a Gestão envia ao gateway. Com o id de
-- login, todo envio automático era recusado (AGENDA_MESSAGING_ACCESS_BINDING_NOT_FOUND).
-- Em produção a mesma correção foi aplicada à mão em 2026-10-21; aqui fica idempotente.
update public.whatsapp_tenant_integrations i
set dispatch_admin_id = au.id
from public.admin_users au
where au.auth_user_id = i.dispatch_admin_id
  and i.dispatch_admin_id is not null;
