# Reconciliação do histórico de migrations do sandbox — 23/08/2026

## Contexto

Algumas migrations de hardening foram aplicadas diretamente no projeto Supabase sandbox durante a auditoria de 23/08/2026 antes de seus arquivos definitivos receberem os timestamps autoritativos no repositório.

O schema resultante estava correto, porém `supabase_migrations.schema_migrations` registrava versões diferentes das versões consolidadas em `main`. Isso impedia `supabase db push` de usar o repositório como fonte autoritativa sem tentar reaplicar mudanças já existentes.

## Reconciliação executada

Somente o identificador de versão do histórico do sandbox foi remapeado; nenhum objeto de domínio, dado de cliente, pagamento ou integração de produção foi alterado.

| Migration | versão antiga no sandbox | versão autoritativa em `main` |
| --- | --- | --- |
| security_advisor_hardening | 20260823041755 | 20260823043000 |
| rls_and_fk_performance_hardening | 20260823041955 | 20260823043100 |
| appointment_token_authorship_foundation | 20260823042303 | 20260823044000 |
| token_verification_lockout_fix | 20260823042438 | 20260823044100 |
| version_hosted_rls_guard | 20260823043540 | 20260823044200 |
| change_workflow_audit_origin | 20260823043647 | 20260823044300 |
| revoke_action_tokens_on_appointment_change | 20260823043717 | 20260823044400 |
| kommo_crm_v1_foundation | 20260823111016 | 20260823080000 |

A equivalência foi confirmada pelo nome e pelos statements registrados no próprio histórico remoto antes do remapeamento. A pequena diferença da migration `security_advisor_hardening` é apenas a guarda condicional de `rls_auto_enable()` adicionada ao arquivo do repositório para permitir rebuild local; no hosted sandbox o objeto existe e o efeito de segurança já estava aplicado.

## Regra daqui em diante

- `supabase/migrations/**` em `main` é a fonte autoritativa de versão e ordem.
- Não aplicar migration permanente diretamente no sandbox com timestamp gerado fora do repositório.
- Diagnóstico temporário não deve permanecer no histórico final.
- O deploy de sandbox deve executar dry-run antes do push.
- Divergência de versão deve falhar o gate em vez de ser corrigida silenciosamente.

## Próxima migration pendente no momento da reconciliação

`20260823091000_expired_hold_availability.sql` ainda não constava no histórico remoto e deve ser aplicada normalmente pelo pipeline autoritativo do sandbox.
