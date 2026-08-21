# Captura de Demanda

Fonte funcional: PROMPT_CAPTURA_DE_DEMANDA.md aprovado em 2026-08-21.

Escopo deliberadamente isolado:

- registra intenção de compra quando não há horário adequado;
- não reserva horário;
- não ocupa recursos;
- não consulta nem altera disponibilidade;
- não implementa fila de espera, prioridade ou janela de exclusividade;
- não envia automação comercial nesta versão;
- exportação CSV é a única transferência para CRM.

Decisões de integração com a Agenda:

- serviços válidos são lidos de `public.services` e somente serviços ativos podem ser enviados;
- marca é contexto da página e é validada server-side contra `DEMAND_CAPTURE_BRANDS`, configuração de ambiente;
- texto e versão de consentimento são configurados por `DEMAND_CAPTURE_CONSENT_TEXT` e `DEMAND_CAPTURE_CONSENT_VERSION`;
- nenhuma tabela auxiliar de marcas ou consentimento é criada para preservar o modelo de dados de tabela única deste módulo;
- timezone de referência: `America/Sao_Paulo`.

Regra editorial pública: não usar travessão tipográfico.
