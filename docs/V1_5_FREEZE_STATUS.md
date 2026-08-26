# V1.5 — freeze de pré-produção

Estado consolidado em 2026-08-26.

## Concluído

- Configurações por operação: #218 / #251.
- Notificações/Templates: fundação, editor/admin, gateway, runtime controlado de e-mail e personalização do Google Calendar: #252, #255, #256, #258, #260, #262.
- Aniversários: fundação, gestão auditada, runtime idempotente, scheduler diário OIDC, worker de entrega com gates fail-closed e prova E2E LOCACAO-only: #253, #259, #264, #271, #273.
- Recursos PERSON x PHYSICAL: prova estrutural #263.
- Snapshot de política V1/V2: contrato canônico read-only #272.
- Observabilidade read-only: #267.
- Índices de cobertura para FKs de aniversário/notificações: #274.
- Wrapper compatível de autorização administrativa já disponível em `supabase/functions/_shared/supabase.ts` via `requireAdminPermission`.

## Bloqueios reais antes do freeze

1. `operation_scope` ainda não pode ser tornado `NOT NULL` sem tratamento explícito das fixtures sintéticas Token Evidence. O contrato administrativo atual também permite limpar o scope para `NULL`; endurecimento deve ocorrer antes do `NOT NULL`.
2. Staging autoritativo: GitHub Pages permanece indisponível (`has_pages=false`), então o staging Lovable não comprova paridade rastreável com um SHA de `main` (#236).

## Não bloqueadores / avaliação

- Facade de outbox: já existem facades específicas para Google, Kommo e confirmação. Consolidação ampla não é necessária para o freeze; somente mudanças incrementais com ganho comprovado.
- Sinal fixo: não implementar sem decisão comercial explícita.

## Gates permanentes

- Sandbox somente para execução técnica.
- Dados sintéticos em staging.
- Nenhum OAuth desassistido, Kommo LIVE, cobrança real, destinatário real, credencial de produção ou cutover sem autorização explícita.
