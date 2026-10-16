# BlackSheep Rewards — S2 controle administrativo (2026-10-15)

## Escopo

S2 transforma a fundação privada do S1 em administração privada e auditável. Continua sem emissão de cupom, mensagem, job, alteração de checkout, reserva, pagamento ou ativação automática.

O backend confiável chama três RPCs `SECURITY DEFINER`, disponíveis somente a `service_role`:

- `service_admin_create_marketing_campaign`: cria uma campanha `DRAFT` e sua versão 1 também `DRAFT` na mesma transação;
- `service_admin_create_marketing_campaign_version`: acrescenta uma versão imutável `DRAFT`;
- `service_admin_transition_marketing_campaign`: executa somente transições permitidas e, quando indicado, publica a versão escolhida.

Cada ação exige `admin_id` ativo com papel `OWNER` ou `ADMIN` e `request_id` UUID. As tabelas continuam sem qualquer grant de escrita direta, inclusive para `service_role`.

## Versão ativa e publicação

`marketing_campaigns.active_version_id` aponta explicitamente para a versão efetiva. A FK composta impede apontar para outra campanha ou tenant. Versões possuem `DRAFT`, `PUBLISHED` ou `SUPERSEDED`; o índice parcial admite somente uma `PUBLISHED` por campanha.

Uma campanha só pode passar a `SCHEDULED` ou `ACTIVE` com uma versão explicitamente publicada. Uma substituição:

1. acrescenta uma versão `DRAFT`;
2. pausa a campanha se ela estiver ativa, quando necessário;
3. em uma transição auditada, torna a versão escolhida `PUBLISHED`, marca a antiga como `SUPERSEDED` e move o ponteiro.

Transições permitidas: `DRAFT → SCHEDULED|ACTIVE|ARCHIVED`; `SCHEDULED → ACTIVE|PAUSED|ENDED|ARCHIVED`; `ACTIVE → PAUSED|ENDED|ARCHIVED`; `PAUSED → ACTIVE|ENDED|ARCHIVED`; `ENDED → ARCHIVED`.

## Regras S2 do Rewards

O contrato administrativo falha fechado se a oferta não for `SERVICE_ONLY`, se incluir extras ou pacote de horas, se permitir mais de um uso total/por cliente, ou se não for `EXCLUSIVE`. Essas validações limitam a configuração; S2 ainda não avalia gatilhos nem cria cupons.

## Auditoria e repetição

Criação registra `CREATED` e `VERSION_CREATED`; alteração de versão e cada transição registram evento obrigatório no mesmo commit. `actor_admin_id` tornou-se obrigatório e usa `ON DELETE RESTRICT`, preservando o sujeito da auditoria. `request_id` é único por ação: repetir uma criação, uma versão ou uma transição retorna o resultado já produzido, sem novo efeito.

## Verificação

- Migration: `supabase/migrations/20261015010000_marketing_campaign_admin_control.sql`.
- pgTAP: `supabase/tests/database/171_marketing_campaign_admin_control.test.sql`, 31 assertions para ACL, papel, estado, publicação, substituição, auditoria, replay e política de oferta.

O reset local continua indisponível nesta máquina porque a porta `54322` pertence a outro projeto Supabase; não interromper esse processo. A validação canônica deverá ocorrer no CI do PR após o push.

## Próximos slices, fora do S2

S3 avalia elegibilidade e gatilhos. S4 poderá emitir cupom por versão publicada, preservando a consistência cliente/origem. S5 integra validade e termos ao checkout. Nenhum desses comportamentos é introduzido por S2.
