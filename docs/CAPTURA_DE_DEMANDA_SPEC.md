# Captura de Demanda

Fonte funcional: `PROMPT_CAPTURA_DE_DEMANDA.md`, recebido em 2026-08-21.

## Escopo

Este modulo registra intencao de compra quando o interessado nao encontrou horario adequado.

Nao faz parte do modulo:

- reservar horario;
- ocupar recurso;
- consultar ou alterar disponibilidade;
- fila de espera;
- prioridade ou janela de exclusividade;
- notificacao automatica de vaga;
- integracao automatica com CRM;
- conta ou login do interessado.

CSV e o unico mecanismo de transferencia para CRM nesta versao.

## Integracao minima com a Agenda

- servicos validos sao lidos de `public.services`, apenas para validar o servico selecionado e obter seu nome;
- marca e contexto da pagina e e validada server-side contra `DEMAND_CAPTURE_BRANDS`;
- texto e versao do consentimento sao configurados por `DEMAND_CAPTURE_CONSENT_TEXT` e `DEMAND_CAPTURE_CONSENT_VERSION`;
- o modulo cria uma unica tabela de negocio: `public.demand_capture`;
- timezone operacional: `America/Sao_Paulo`.

## Regra editorial

Conteudo publico nao usa travessao tipografico.
