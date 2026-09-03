# Item 4 — retirada da capability plaintext de checkout recovery

Issue: #384

## Finding

A auditoria profunda identificou `public.checkout_holds.recovery_public_token` como capability de recuperação armazenada em texto puro.

A reauditoria read-only confirmou no estado produtivo anterior ao Item 4:

- `recovery_public_token text NOT NULL default encode(gen_random_bytes(24), 'hex')`;
- índice único sobre o token legível;
- `recovery_token_expires_at NOT NULL default now() + interval '7 days'`;
- `get_checkout_hold_resume_context(text)` comparando diretamente `recovery_public_token`;
- `set_checkout_hold_recovery_contact(text,text,boolean)` ainda capaz de habilitar recovery;
- `public_bind_checkout_customer(..., p_recovery_enabled boolean default true)` ainda capaz de persistir `recovery_enabled=true`.

Mesmo holds com `recovery_enabled=false` recebiam automaticamente um segredo legível e validade de sete dias.

## Estado operacional antes da correção

Produção tinha 27 checkout holds históricos, mas:

- zero recovery habilitados;
- zero recovery habilitados e não expirados;
- zero holds ativos;
- zero holds ativos recuperáveis;
- zero `integration_jobs` relacionados a recovery;
- nenhuma view ou trigger consumindo a capability;
- o Edge Function `booking-checkout` chama `public_bind_checkout_customer` explicitamente com `p_recovery_enabled=false`.

A feature de recovery direto já estava operacionalmente aposentada. O Item 4 não a reimplementa.

## Correção

A migration `20260902233000_retire_checkout_recovery_plaintext.sql`:

1. falha antes de alterar o schema se existir um hold ativo e recuperável;
2. preserva as assinaturas de `get_checkout_hold_resume_context(text)` e `set_checkout_hold_recovery_contact(text,text,boolean)`, mas as transforma em stubs `CHECKOUT_RECOVERY_RETIRED`;
3. preserva a assinatura de `public_bind_checkout_customer`, muda o default de `p_recovery_enabled` para `false` e faz qualquer chamada explícita com `true` falhar com `CHECKOUT_RECOVERY_RETIRED`;
4. mantém toda a lógica existente de identidade/customer binding para o caminho normal e persiste recovery sempre como desabilitado;
5. remove default e `NOT NULL` de `recovery_token_expires_at`;
6. invalida o estado histórico de recovery;
7. remove o índice e a coluna `recovery_public_token` sem `CASCADE`;
8. adiciona e valida `checkout_holds_recovery_retired_check`, impedindo `recovery_enabled=true` por qualquer writer.

A assinatura de `public_bind_checkout_customer` é mantida para compatibilidade. O parâmetro legado não reativa a feature: omitido ou `false` segue o checkout normal; `true` falha fechado.

## Failing-before / passing-after

`scripts/test-item04-checkout-recovery-retirement.sh` exige exatamente onze findings antes da migration:

1. coluna plaintext presente;
2. coluna plaintext `NOT NULL`;
3. default de segredo presente;
4. índice do token presente;
5. expiração `NOT NULL`;
6. default de expiração presente;
7. lookup plaintext no RPC de resume;
8. setter ainda vivo;
9. `public_bind_checkout_customer` com default legado `true`;
10. `public_bind_checkout_customer` ainda capaz de persistir recovery;
11. constraint de aposentadoria ausente.

Depois da migration, o mesmo inventário deve retornar zero findings. O pgTAP específico prova ainda que:

- não existe coluna plaintext;
- novos holds não recebem expiração de recovery;
- as RPCs legadas falham fechadas;
- `public_bind_checkout_customer(..., true)` falha fechado;
- o default do bind é `false`;
- anon continua sem `EXECUTE` nas fronteiras aposentadas;
- holds expiram e liberam recursos normalmente;
- nenhum job de WhatsApp recovery reaparece;
- o template legado permanece inativo.

O contrato normal de checkout usa `p_recovery_enabled=false` e continua coberto por `019_public_checkout_details.test.sql`. O contrato adversarial introduzido no PR #77 continua cobrindo que recovery não ressuscita alocação; agora a capability inteira falha fechada em `041_public_surface_adversarial.test.sql`.

## Produção e rollback

Antes do deploy deve ser confirmado novamente que não existe recovery ativo/recuperável em produção.

A migration é versionada e só pode ser aplicada depois de merge com todos os gates do HEAD verdes. O smoke pós-deploy é read-only e deve confirmar retirada da coluna, stubs fail-closed, bind com default `false`, constraint validada, zero recovery habilitado e invariantes normais de checkout/RLS.

Os tokens plaintext históricos são intencionalmente invalidados e não são recuperáveis após o `DROP COLUMN`. Se o smoke normal falhar por incompatibilidade estrutural não detectada no rebuild, o rollback deve ser uma nova migration versionada que restaure apenas compatibilidade estrutural necessária, sem recriar defaults de segredo nem reativar recovery.

## Fora de escopo

Não altera Google Calendar, Mercado Pago, Kommo, serviços, preços, políticas comerciais, disponibilidade, pagamentos ou configuração de locação.
