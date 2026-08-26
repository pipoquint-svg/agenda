# I-09 — tratamento determinístico das fixtures sem política

Inventário autoritativo do sandbox identificou somente dois serviços ativos sem `service_change_policies`, ambos sintéticos:

- `[TESTE] Locação BlackSheep Kommo` — BLACKSHEEP, preço zero;
- `Token Evidence Service` — operação nula, preço 100, origem das fixtures `TOKEN-EVIDENCE-1/2`.

A migration de hardening **não inventa política comercial**. Ela somente desativa esses dois serviços se, no momento da aplicação, continuarem ativos e sem política. Histórico e reservas sintéticas são preservados.

Os serviços gratuitos de staging inventariados (`Conheça o Estúdio — visita gratuita` e `Visita BlackSheep — 30 min`) já têm política e não são alterados.

O catálogo futuro de produção é responsabilidade da fase Provisionamento de Produção e deve nascer satisfazendo a invariante de política própria para todo serviço ativo.
