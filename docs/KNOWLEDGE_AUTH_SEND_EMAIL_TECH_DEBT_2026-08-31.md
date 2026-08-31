# Knowledge — dívida conhecida de `auth-send-email`

Data: 2026-08-31
Status: dívida técnica conhecida e deliberadamente adiada
Escopo: BlackSheep Agenda / autenticação

## Estado atual confirmado

A Edge Function `supabase/functions/auth-send-email/index.ts` continua responsável pelos e-mails transacionais do Supabase Auth.

Hoje ela:

- valida o webhook de autenticação;
- monta assunto, texto e HTML dentro da própria função, por `email_action_type`;
- escolhe o remetente pelo escopo da operação;
- envia diretamente pelo adapter compartilhado `sendEmailWithProvider`;
- usa chave de idempotência no envio ao provider.

## Dívida conhecida

`auth-send-email` ainda está **fora da plataforma administrativa de templates** e **não grava o delivery log padronizado** usado pela esteira normal de notificações/e-mails.

Consequências conhecidas:

1. alterações de conteúdo dos e-mails de autenticação exigem mudança de código/deploy;
2. esses envios não aparecem no mesmo histórico operacional de delivery da plataforma de templates;
3. observabilidade e auditoria ficam inferiores às dos demais e-mails transacionais integrados.

## Decisão

Não migrar `auth-send-email` neste Bloco 3 de higiene.

O adiamento é deliberado para não misturar uma refatoração sensível de autenticação com correções de higiene já estabilizadas. O comportamento atual de login, convite, confirmação, recuperação, troca de e-mail e notificações de segurança deve permanecer inalterado até existir uma etapa própria para essa migração.

## Critério para quitar a dívida

Uma etapa futura só deve considerar esta dívida encerrada quando:

- o conteúdo de autenticação usar a plataforma oficial de templates ou uma camada equivalente, versionada e administrável;
- todo envio registrar delivery log com operação, destinatário, tipo de ação, provider, status e identificador de correlação/idempotência, sem persistir token secreto em claro;
- os fluxos `signup`, `invite`, `magiclink`, `recovery`, `email_change`, reautenticação e notificações de segurança tiverem testes de regressão;
- falhas de template/log não abrirem bypass de autenticação nem alterarem a semântica do webhook do Supabase Auth;
- houver plano de deploy/rollback separado e validação E2E antes de produção.

## Regra de manutenção

Enquanto esta dívida estiver aberta, mudanças em `auth-send-email` devem ser tratadas como mudança de autenticação, com revisão e testes próprios. Não assumir que a função participa automaticamente das garantias da plataforma de templates ou do delivery log.
