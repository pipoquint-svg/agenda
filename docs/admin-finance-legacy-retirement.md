# `admin-finance` legado — decisão de aposentadoria

Data da decisão: 2026-08-30.

## Decisão

`admin-finance` está **aposentado/frozen**. Ele não é a API financeira da BlackSheep Gestão e não deve receber novas features, correções de contrato ou novos consumidores.

A superfície autoritativa usada por `/gestao` é `admin-finance-minimal` e os RPCs financeiros atuais da Agenda.

## Evidência antes da decisão

- O frontend atual da Gestão não possui consumidor conhecido de `admin-finance`.
- Os fluxos críticos financeiros usam `admin-finance-minimal`.
- A inspeção dos logs de Edge Functions disponível em 2026-08-30 não mostrou chamada a `admin-finance` nas últimas 24 horas.
- O endpoint legado ainda está implantado e funcional; por isso não deve ser quebrado silenciosamente no mesmo commit de higiene.

## Regra a partir daqui

1. Não criar nenhum novo consumidor de `admin-finance`.
2. Não expandir seu contrato.
3. Manter o endpoint congelado somente durante a janela de observação de compatibilidade.
4. Após **7 dias consecutivos sem chamadas identificadas**, remover a Edge Function implantada e o código legado em uma mudança isolada, com rollback claro.
5. Se uma chamada aparecer durante a janela, identificar o consumidor e migrá-lo para a superfície autoritativa antes da retirada.

A aposentadoria não autoriza duplicar regras financeiras no frontend nem recriar a API sob outro nome.
