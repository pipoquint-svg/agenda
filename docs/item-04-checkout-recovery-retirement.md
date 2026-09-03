# Item 4 — retirada da capability plaintext de checkout recovery

Issue: #384

## Finding

A auditoria profunda identificou `public.checkout_holds.recovery_public_token` como capability de recuperação armazenada em texto puro.

A auditoria read-only realizada antes desta mudança confirmou que o estado real ainda continha:

- `recovery_public_token text NOT NULL default encode(gen_random_bytes(24), 'hex')`;
- índice único sobre o token legível;
- `recovery_token_expires_at NOT NULL default now() + interval '7 days'`;
- `get_checkout_hold_resume_context(text)` comparando diretamente `recovery_public_token`;
- `set_checkout_hold_recovery_contact(text,text,boolean)` ainda capaz de habilitar recovery;
- `public_bind_checkout_customer(..., p_recovery_enabled boolean)` ainda capaz de persistir `recovery_enabled=true`.

Mesmo holds com `recovery_enabled=false` recebiam automaticamente um segredo legível e uma validade de sete dias.

## Estado operacional antes da correção

Produção tinha 27 checkout holds históricos, mas:

- zero recovery habilitados;
- zero recovery habilitados e não expirados;
- zero holds ativos;
- zero holds ativos recuperáveis;
- zero `integration_jobs` relacionados a recovery;
- nenhum RPC público chamando `get_checkout_hold_resume_context`;
- o Edge Function `booking-checkout` chama `public_bind_checkout_customer` explicitamente com `p_recovery_enabled=false`.

A feature de recovery direto já estava operacionalmente aposentada. O Item 4 não a reimplementa.

## Correção

A migration `20260902233000_retire_checkout_recovery_plaintext.sql`:

1. falha antes de alterar o schema se existir um hold ativo e recuperável;
2. preserva as assinaturas de `get_checkout_hold_resume_context(text)` e `set_checkout_hold_recovery_contact(text,text,boolean)`, mas as transforma em stubs `CHECKOUT_RECOVERY_RETIRED`;
3. remove default e `NOT NULL` de `recovery_token_expires_at`;
4. invalida o estado histórico de recovery;
5. remove o índice e a coluna `recovery_public_token`;
6. adiciona e valida `checkout_holds_recovery_retired_check`, impedindo `recovery_enabled=true` por qualquer writer.

`public_bind_checkout_customer` não é reescrita. O fluxo normal mantém sua lógica atual de identidade e cliente; callers que passarem `p_recovery_enabled=false` continuam inalterados. Qualquer tentativa de `true` é rejeitada estruturalmente pela constraint.

## Failing-before / passing-after

`scripts/test-item04-checkout-recovery-retirement.sh` exige exatamente nove findings antes da migration:

1. coluna plaintext presente;
2. coluna plaintext `NOT NULL`;
3. default de segredo presente;
4. índice do token presente;
5. expiração `NOT NULL`;
6. default de expiração presente;
7. lookup plaintext no RPC de resume;
8. setter ainda vivo;
9. constraint de aposentadoria ausente.

Depois da migration, o mesmo inventário deve retornar zero findings. O teste pgTAP `015_short_hold_recovery.test.sql` prova ainda que:

- não existe coluna plaintext;
- novos holds não recebem expiração de recovery;
- as RPCs legadas falham fechadas;
- anon continua sem `EXECUTE`;
- holds expiram e liberam recursos normalmente;
- nenhum job de WhatsApp recovery reaparece;
- o template legado permanece inativo.

O workflow dedicado também executa o contrato completo de banco após o passing-after.

## Produção e rollback

Antes do deploy deve ser confirmado novamente que não existe recovery ativo/recuperável em produção.

A migration é versionada e deve ser aplicada somente depois de merge com todos os gates verdes. O smoke pós-deploy é read-only e deve confirmar a retirada da coluna, stubs fail-closed, constraint validada, zero recovery habilitado e invariantes normais de checkout/RLS.

Os 27 tokens plaintext históricos são intencionalmente invalidados e não são recuperáveis após o `DROP COLUMN`. Se um smoke normal falhar por incompatibilidade estrutural não detectada no rebuild, o rollback deve ser uma nova migration versionada que restaure apenas compatibilidade estrutural necessária, sem recriar defaults de segredo nem reativar recovery.

## Fora de escopo

Não altera Google Calendar, Mercado Pago, Kommo, serviços, preços, políticas comerciais, disponibilidade, pagamentos ou configuração de locação.
