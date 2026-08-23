# BlackSheep — locação por duração e visita gratuita

Status: decisão de produto aprovada em 2026-08-23.

## Locação BlackSheep

A experiência pública da booking page `blacksheep` é orientada a **tempo**, não a catálogo de serviços.

- Existe um único produto técnico de locação no backend.
- O cliente não escolhe o serviço; escolhe a duração.
- Bloco configurável no backend; configuração atual de staging: 30 minutos.
- Mínimo atual: 1h (2 blocos).
- Ajuste: ± 30 minutos.
- Presets editoriais: 2h, 4h e 8h. Presets são atalhos de UX, não produtos e não definem preço.
- A tela inicial da jornada já apresenta a quote autoritativa, antes de dados pessoais/hold.
- Ordem BlackSheep: Tempo → Pessoas → Extras → Data/horário → Dados → Revisão → Pagamento → Confirmação.
- Buffer é operacional, não faturável, e não reduz o tempo contratado.

## Preço

- Backend é a única fonte de verdade.
- Frontend usa as RPCs de quote para total e preço efetivo por hora.
- `service_duration_pricing_tiers` controla descontos progressivos.
- `service_duration_presets` é apenas editorial.
- Nunca hardcodar desconto/tabela financeira no frontend.
- Economia/preço riscado só aparece quando existir redução real comprovada pela quote.

## Home

A Home pode oferecer calculadora read-only de duração/preço, sem cadastro e sem criar hold.

- CTA primário: `Reservar esse tempo`, preservando `duration_blocks` na navegação para `/agenda-e-valores`.
- CTA secundário: `Conhecer o estúdio sem compromisso`.

## Visita gratuita

Fluxo separado da locação, usando booking page técnica própria (`blacksheep-visita`).

- 30 minutos.
- R$ 0.
- Sem Mercado Pago e sem etapa de pagamento.
- Sem CPF quando `require_tax_id=false`.
- Fluxo visual: Data/horário → Dados (nome, telefone/WhatsApp, e-mail) → Revisão → Confirmação.
- Internamente pode reutilizar hold/bind/submit autoritativos.
- `cash_due=0` deve resultar em `CONFIRMED/PAID` e pular pagamento no frontend.
- A visita usa o mesmo recurso físico da locação, portanto deve bloquear conflitos de horário normalmente.

## Sabrina / generic

Estas regras são específicas para a booking page BlackSheep. Sabrina e demais páginas genéricas preservam seleção de serviços e suporte a serviços `FIXED`.

## Segurança e staging

- Staging sem dados reais e sem cobranças reais.
- Google permanece desconectado até gate específico futuro.
- Validação automatizada do frontend deve parar antes da primeira mutação sempre que houver risco de enviar e-mail/gerar compromisso.
