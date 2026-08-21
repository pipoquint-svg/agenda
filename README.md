# BlackSheep Agenda

Sistema de agendamento operacional da BlackSheep / Sabrina Pierri.

## Estado atual

Implementação do **Marco A — Core**. O primeiro gate técnico é provar que dupla reserva é impossível no banco.

### Princípios já implementados

- PostgreSQL/Supabase como fonte de verdade;
- `timestamptz` para instantes;
- `tstzrange [start,end)` para ocupação;
- recursos físicos/humanos como entidades planas;
- `resource_allocations` como mecanismo único de conflito;
- `EXCLUDE USING gist` para impedir sobreposição em recurso bloqueante;
- checkout hold de 10 minutos e payment hold padrão de 30 minutos na configuração base.

## Desenvolvimento local

Pré-requisitos:

- Docker compatível;
- Supabase CLI;
- PostgreSQL client (`psql`) para o teste concorrente.

```bash
supabase start
supabase db reset
supabase test db
bash scripts/test-concurrency.sh
```

O teste concorrente lança 20 tentativas simultâneas para o mesmo recurso/intervalo. O resultado válido é exatamente **1 sucesso e 19 rejeições**.

## Reprodutibilidade

Schema e regras de integridade devem existir em `supabase/migrations/`. Não criar alterações obrigatórias apenas pelo Dashboard do Supabase.

Credenciais, tokens e dados reais nunca devem ser commitados neste repositório.
