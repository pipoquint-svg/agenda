# Regras financeiras por serviço

## Pagamento mínimo no checkout

Todo serviço, independentemente de `duration_mode` (`FIXED` ou `BLOCKS`), possui uma regra explícita de pagamento mínimo:

- `checkout_minimum_payment_type`: `PERCENT` ou `FIXED`;
- `checkout_minimum_payment_value`: percentual ou valor em reais, conforme o tipo.

O checkout público oferece somente duas escolhas financeiras:

1. `MINIMUM`: o mínimo autoritativo calculado pelo backend a partir do snapshot da reserva;
2. `FULL`: o saldo integral devido.

O frontend nunca recalcula a regra financeira. Para `FIXED`, o mínimo é limitado ao saldo/valor total da reserva. A regra é congelada no appointment no momento da criação, portanto mudanças futuras no cadastro do serviço não alteram reservas anteriores.

Serviços existentes foram migrados preservando a regra anterior como `PERCENT / 50`.

## Multas de remarcação e cancelamento

Cada campo da política possui tipo e valor independentes:

- primeira remarcação fora da janela;
- primeira remarcação dentro da janela;
- remarcações seguintes/reincidência;
- cancelamento dentro da janela.

Cada multa aceita `PERCENT` ou `FIXED`. Percentuais legados foram preservados como regras `PERCENT` durante a migração. Reservas existentes continuam usando seus snapshots históricos.

O cancelamento fora da janela permanece sem multa conforme a política consolidada vigente.
