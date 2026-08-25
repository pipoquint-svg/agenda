# Admin catalog requirements — 2026-08-25

Authoritative hierarchy: `OPERATION -> CATEGORY -> SERVICE`.

## Operations
- `SABRINA`
- `BLACKSHEEP`

Each operation owns its own categories. A service must belong to one category from the same operation.

## Categories
Admin must support list/create/edit/reorder/activate/archive. Physical deletion is only allowed when no service/history dependency exists.

## Services
Admin must support list/create/edit/reorder/activate/archive and expose:
- public short/full description;
- base duration, before/after buffers;
- base price;
- minimum/maximum people;
- per-extra-person pricing;
- day/time price rules (`DAY_TIME` using `REPLACE_PRICE`, `ADD_AMOUNT`, `ADD_PERCENT`);
- custom intake fields;
- linked extras;
- change/cancellation policy.

## Extras
One reusable catalog. Each extra has name, public description, price, duration and active state. A service chooses which extras are offered, order, required flag, max quantity and temporal placement (`PREPEND` / `APPEND`).

## Custom fields
Per-service fields: TEXT, TEXTAREA, NUMBER, DATE, SELECT, MULTISELECT, BOOLEAN; label, key, help, placeholder, required, options, order and active state.

## Safety
All administrative writes are authenticated, permission-gated and audited. Existing appointments keep snapshots. Deleting a catalog object with historical dependencies must archive/deactivate instead of cascading history.
