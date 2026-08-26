# V1.5 — prova do modelo PERSON x PHYSICAL

## Conclusão

O modelo atual já suporta a configuração necessária para Sabrina/Fê sem nova dimensão de taxonomia e sem mudança arquitetural:

- `resources.resource_type` distingue `PHYSICAL` e `PERSON`;
- `employees.resource_id` permite vincular cada profissional ao seu próprio recurso `PERSON`;
- `service_resources` permite que o mesmo serviço exija simultaneamente o estúdio (`PHYSICAL`) e o profissional (`PERSON`);
- `google_calendar_resources` permite mapear o calendário bloqueador do profissional ao respectivo recurso;
- `resource_allocations` possui exclusão GiST por `resource_id + occupied_range`, de forma que duas reservas que exigem o mesmo estúdio não podem ocupar intervalos sobrepostos, ainda que os profissionais sejam diferentes.

Portanto, para Sabrina e Fê, a configuração correta é:

1. um recurso `PHYSICAL` compartilhado para o estúdio;
2. um recurso `PERSON` independente para cada profissional;
3. `employees.resource_id` apontando para o recurso da pessoa, nunca para o estúdio;
4. serviço de ensaio exigindo o estúdio e o profissional aplicável;
5. calendário Google bloqueador de cada profissional mapeado ao recurso `PERSON` correspondente.

## Estado observado no sandbox

O sandbox ainda contém apenas um recurso físico `[STAGING] Estúdio BlackSheep`. O employee `[STAGING] Recurso Agenda` aponta para esse mesmo recurso físico. Esse estado é configuração sintética de staging e não deve ser copiado para produção como modelo de profissional.

A correção dessa configuração pertence ao provisionamento do catálogo/recursos do ambiente-alvo. Este item V1.5 apenas prova que o modelo autoritativo já suporta a configuração correta.

## Invariante operacional

Mesmo com dois recursos `PERSON`, Sabrina e Fê não podem atender simultaneamente dentro do estúdio quando ambos os serviços exigirem o recurso físico compartilhado: a constraint de exclusão de `resource_allocations` rejeita sobreposição no mesmo `resource_id`.

## Não muda

- nenhuma migration;
- nenhum dado de sandbox;
- nenhum calendário ou OAuth;
- nenhuma regra de disponibilidade;
- nenhum contrato público;
- nenhum provider ou produção.
