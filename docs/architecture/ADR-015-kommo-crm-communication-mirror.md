# ADR-015 — Kommo como CRM e camada de comunicação BlackSheep

**Status:** Aceito  
**Data:** 23/08/2026

## Contexto

A V1 possuía uma trilha de WhatsApp direto para recuperação simples de checkout. Manter uma integração própria com Meta/WhatsApp adicionaria número dedicado, credenciais, templates, webhooks e operação de mensageria a um sistema cujo domínio principal é reserva.

A operação BlackSheep também precisa de histórico comercial e capacidade futura de campanhas para clientes que alugam o estúdio.

## Decisão

Adotar Kommo como CRM externo e camada de comunicação para reservas com `services.operation_scope = 'BLACKSHEEP'`.

A Agenda continua sendo a fonte da verdade. O Kommo recebe um espelho idempotente da reserva.

Modelo:

- `customer` Agenda → Contato Kommo;
- `appointment` Agenda → Lead Kommo;
- uma pessoa pode possuir vários Leads, um por reserva;
- remarcação e cancelamento atualizam o mesmo Lead;
- Kommo dispara WhatsApp/e-mail por automações do pipeline;
- mailbox operacional BlackSheep: `agenda@blacksheepestudiocriativo.com.br`.

Para `operation_scope = 'SABRINA'`:

- nenhum sync Kommo;
- nenhuma confirmação automática por e-mail na configuração atual.

## Direção de dados

V1: `Agenda → Kommo` somente.

Kommo não pode confirmar, cancelar, remarcar, alterar preço ou modificar qualquer estado autoritativo da Agenda.

## Falhas

Indisponibilidade do Kommo não bloqueia a reserva. O sync usa `integration_jobs` com idempotência e retry.

A integração fica `enabled=false` até o provider spike real comprovar conta, pipeline, contato, Lead, update do mesmo Lead e idempotência.

## Segurança

- token Kommo apenas em Edge secret;
- nunca em tabela, frontend ou logs;
- IDs externos podem ser persistidos apenas para correlação;
- dados enviados limitados ao necessário para CRM/comunicação da reserva;
- Sabrina é fail-closed por `operation_scope`.

## Consequências

### Positivas

- remove Meta/WhatsApp direto do motor da Agenda;
- reduz integrações e número dedicado mantidos pela aplicação;
- cria CRM útil para operação e campanhas futuras BlackSheep;
- centraliza comunicação comercial no sistema já projetado para isso;
- preserva a Agenda como domínio transacional enxuto.

### Negativas

- Kommo torna-se dependência operacional para notificações BlackSheep;
- pipeline, mailbox e automações precisam ser configurados e testados externamente;
- campanhas e comunicação passam a depender das capacidades/limites do Kommo.

## Substitui

A trilha ativa de `CHECKOUT_HOLD_EXPIRED_RECOVERY → whatsapp-send-template` deixa de fazer parte da V1. Dados históricos e migrations antigas permanecem preservados, mas a superfície pública e o worker deixam de gerar esse envio.
