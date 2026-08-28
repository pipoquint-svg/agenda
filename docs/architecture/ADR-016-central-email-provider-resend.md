# ADR-016 — Provedor central de e-mail

## Status
Aprovado.

## Decisão
Todo e-mail emitido pela Agenda usa **Resend** como provedor único.

Isso inclui, sem exceção:
- autenticação e recuperação de senha;
- convites, confirmações e alertas de segurança do Supabase Auth;
- confirmações de reserva;
- cobrança de saldo;
- aniversários;
- notificações e lembretes;
- integrações futuras que precisem enviar e-mail.

## Implementação canônica
O único módulo autorizado a conhecer a credencial e o endpoint do provedor é:

`supabase/functions/_shared/email-provider.ts`

As Edge Functions consumidoras devem chamar `sendEmailWithProvider()` e resolver o remetente por `senderForScope()` quando aplicável.

O Supabase Auth deve usar o **Send Email Hook** `auth-send-email`, que também chama o mesmo módulo. Com o hook ativo, o SMTP padrão do Supabase não participa do envio.

## Segredos e remetentes
- `RESEND_API_KEY` é o único segredo de provedor de e-mail.
- remetentes continuam definidos por escopo (`EMAIL_FROM_BLACKSHEEP`, `EMAIL_FROM_SABRINA` e respectivos reply-to);
- nenhum segredo de provedor pode ser hardcoded ou duplicado em função individual.

## Invariante de CI
`scripts/test-central-email-provider.sh` falha se uma Edge Function tentar acessar diretamente `RESEND_API_KEY`, o endpoint do Resend ou um host SMTP fora do módulo canônico.

## Consequências
- não existe fallback silencioso para SMTP padrão do Supabase;
- falha de configuração deve ser explícita e fail-closed;
- novos fluxos de e-mail devem reutilizar o provedor central, sem implementação paralela.
