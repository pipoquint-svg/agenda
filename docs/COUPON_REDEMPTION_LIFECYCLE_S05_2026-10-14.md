# S0.5 — Coupon redemption lifecycle, 2026-10-14

Slice S0.5 of the BlackSheep Rewards audit. It stabilizes the existing coupon infrastructure; it does not implement campaigns.
Branch `fix/coupon-lifecycle-s05-20261014` (base `origin/main` `f2600f4`). Migration `20261014203000_coupon_redemption_lifecycle.sql`. Not merged, not deployed.

## Problems fixed

| # | Problem (before) | Fix |
|---|---|---|
| A | `used_count` was the only usage state. It was incremented when the hold became an appointment (`AWAITING_PAYMENT`), so “reserved” and “consumed” were indistinguishable. | `appointment_discounts` is the redemption ledger: `RESERVED` (appointment not confirmed), `REDEEMED` (appointment `CONFIRMED`/`COMPLETED`/`NO_SHOW`), `RELEASED` (`released_at`, or appointment `EXPIRED`/`CANCELLED`). `used_count` keeps counting RESERVED + REDEEMED, so a pending reservation still blocks a single-use coupon. |
| B | `release_appointment_coupon_usage` decremented on every call. Five call sites, so a double release could reopen another reservation's use. | `service_release_appointment_coupon` marks `released_at` once and returns the use at most once. The legacy function delegates to it. The trigger `appointments_coupon_redemption_lifecycle` also releases on any transition to `EXPIRED`/`CANCELLED`, including paths that never called the release (for example prebook expiry). |
| C | The per-customer limit counted every `appointment_discounts` row, including expired or cancelled ones. A customer who abandoned a Pix lost a coupon with `max_uses_per_customer = 1`, the birthday shape. | Both guards (`enforce_coupon_customer_usage_limit`, `enforce_checkout_coupon_customer`) count only non-RELEASED redemptions. History rows are kept. |
| D | Concurrency was already serialized by `FOR UPDATE` on the coupon row at promotion. | Kept, and now proven with parallel sessions in `scripts/test-coupon-concurrency.sh` (global and per-customer limits). |
| E | Both pricing cores applied the discount to `subtotal = service + surcharges + people + extras`. | New `coupons.discount_scope`: `ORDER_SUBTOTAL` (default, identical arithmetic) or `SERVICE_ONLY` (excludes extras, keeps day/time and holiday surcharges and people adjustments). Applied in `calculate_booking_quote_catalog_base` (FIXED), `calculate_booking_quotes_for_duration_batch` (BLOCKS), the legacy direct-coupon path in `promote_checkout_hold_standard`, and both reschedule paths through `appointment_discounts.discount_scope_snapshot`. Single formula: `coupon_discount_amount`. |

## Consumption policy now in code

- **Pix/card pending, rejected or provider-expired:** RESERVED until the payment hold expires, then RELEASED.
- **Approved minimum payment (50%) or full payment:** the appointment is confirmed, so the coupon is REDEEMED. `PARTIALLY_PAID` is kept distinct from `PAID`.
- **Invoice confirmation (`UNPAID_AUTHORIZED`):** REDEEMED, because it is a confirmed contractual obligation.
- **Abandoned checkout:** never promoted, so nothing is consumed.
- **Cancellation:** RELEASED, as before (the coupon returns). Changing this is a commercial decision (S0 J-6).
- **Hour package plus coupon:** still rejected with `COUPON_PACKAGE_POLICY_REQUIRES_DECISION`.

## Preserved (no commercial change)

- Every existing coupon and the birthday automation use `ORDER_SUBTOTAL`. Their discount base is unchanged; tests prove identical arithmetic.
- Birthday settings (disabled, 50%, 30 days, single use) are untouched.
- No appointment status is written by the new code. The new trigger writes only `appointment_discounts`/`coupons`, so no Kommo or integration job is enqueued (tested).
- The admin coupon APIs keep their signatures. `admin_list_coupons[_page]` gain the additive keys `reserved_count` and `discount_scope`; `admin_coupon_usage` gains `redemption_status`, `released_at` and `release_reason`; uses and metrics ignore RELEASED rows.
- No data backfill. New columns are nullable or constant-default (metadata-only). Rows created before S0.5 are classified at read time from the appointment status, and a direct release of such a row does not return the counter a second time.

## Coupon consumption vs reward issuance (definitive distinction)

These are two different events and must never share a trigger:

- **Coupon consumption (this slice):** a coupon is consumed (`REDEEMED`) when the reservation that received the discount is validly confirmed (appointment `CONFIRMED`: approved minimum or full payment, confirmed invoice, zero-due confirmation). Before that it is only `RESERVED`; expiry, payment failure or cancellation release it.
- **Reward issuance (future BlackSheep Rewards engine, S3/S4):** a new reward coupon is issued only after the rental is effectively completed **and** financially regularized. Confirmation, payment of the 50% minimum, or the end time passing are not enough. The appointment lifecycle has no runtime `COMPLETED` transition yet (S0 finding P0-1), so issuance cannot be built on this slice alone.

A rental that used a reward coupon consumes it at confirmation. The same rental can generate the next reward later, at its own completion and regularization.

## Definitive commercial rule: coupon validity (recorded 2026-10-14)

> The coupon is valid for 30 days to **confirm** a new reservation. There is no date limit for when the future rental takes place.

Current code does **not** implement this rule for any coupon, and this slice does not change it:

- `apply_checkout_coupon`, `enforce_checkout_coupon_customer` and `promote_checkout_hold_standard` check `now()` against `valid_from`/`valid_until`.
- Both pricing cores also reject the coupon when the **rental start** is outside `valid_from`/`valid_until` (`INVALID_COUPON`). This is incompatible with “no date limit for the rental”.

Existing coupons keep today's behavior, since changing it would alter their commercial conditions. The Rewards coupon needs an explicit, coupon-level validity basis (for example `validity_basis = 'CONFIRMATION'`, evaluated at `now()` only). That belongs to the Rewards engine slices (S1/S5), together with a defined rule for a reservation created before expiry whose payment confirmation arrives after it.

## SERVICE_ONLY is mandatory for BlackSheep Rewards

Every coupon issued by the future Rewards campaign must be created with `discount_scope = 'SERVICE_ONLY'`. S1 must enforce this with a table constraint on the campaign source, not only in application code. Tested here: FIXED and BLOCKS paths, night surcharge kept in the base, extras excluded, fixed amount capped at the rental, reschedule snapshot.

Open definition: `SERVICE_ONLY` keeps additional-people adjustments in the base and excludes only catalog extras. Open PR #471 treats additional people as non-eligible. Decide before S1 whether additional people belong to the rental base.

## Security review (SECURITY DEFINER)

- `trg_appointment_discount_lifecycle_defaults()` and `trg_appointment_coupon_redemption_lifecycle()` are SECURITY DEFINER, owned by `postgres`, with `search_path = public, pg_temp`. Every object is schema-qualified, and no role (including `service_role`) has EXECUTE: trigger-only, asserted by the ACL overlay. They read or write only the row of the firing appointment and its coupon; no dynamic SQL, no caller input.
- `admin_coupon_metrics()` and `admin_coupon_usage(uuid)` remain SECURITY DEFINER read models restricted to `service_role` (EXECUTE preserved by `create or replace`); their search path is now `public, pg_temp`.
- The new helpers `coupon_discount_amount`, `coupon_redemption_status` and `service_release_appointment_coupon` are SECURITY INVOKER and executable only by `service_role` (asserted by the overlay and pgTAP).

## Relation to other open PRs

- **#471 (fix/coupons-rental-only-20261006):** changes every coupon to a rental-only base (excludes extras and additional people), patches the same functions and adds its own scope metadata. It is mutually exclusive with this slice, which keeps existing coupons unchanged and makes the rental-only base opt-in. Only one can be merged without a rebase; this needs a user decision.
- **#491 (notification scheduling):** uses migration version `20261014190000`; this slice was renamed to `20261014203000` to avoid a version collision. Both PRs set absolute counts in `item02c_acl_overlay.sql`, so whichever merges second must rebase and adjust the counts.

## Not changed / residual

- `SERVICE_ONLY` can be set only by SQL until the admin RPC/UI exposes it (S2). No coupon uses it yet.
- `calculate_booking_quote_base` has no callers and was left untouched.
- Function patches use exact-text anchors taken from a canonical rebuild and fail atomically on drift. If production definitions differ from the repository, the deploy stops before changing anything.
- Historical `used_count` values may already differ from active redemptions where a past expiry path skipped the release. Read-only check before or after release:

```sql
select c.id, c.code, c.used_count,
       count(*) filter (where public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED') as active_redemptions
from public.coupons c
left join public.appointment_discounts ad on ad.coupon_id = c.id
left join public.appointments a on a.id = ad.appointment_id
group by c.id
having c.used_count <> count(*) filter (where public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED');
```

Any correction from that query is a separate, explicitly authorized data operation.

## Verification (local, isolated stack)

- Clean rebuild from all migrations: OK.
- Full pgTAP: 172 files, 2159 tests, PASS (main baseline: 171 files, 2094 tests). New file `169_coupon_redemption_lifecycle.test.sql`: 65 assertions.
- ACL overlay `ITEM02C_ACL_OVERLAY_OK` (480 public functions / 412 service_role EXECUTE, five new identities asserted). RLS overlay OK. Gestão critical fixture OK.
- Concurrency: Gate A, pre-reservation, package, coupon (8 and 12 parallel attempts, one success), rate limit. All PASS.
- Item 16 pgTAP plan, item 2D deploy gate, migration-history baseline: PASS. Item 2C after-mode assertions: PASS (overlay plus 6 files; the script needs bash ≥ 4 for `mapfile`, so it was emulated locally).
- `supabase db lint --level error`: no new findings. Pre-existing: pgTAP internals and `penalty_due_now` in `service_admin_create_reschedule_hold_unchecked`.

## Release order (when authorized)

1. PR CI green on the final HEAD.
2. Protected backup (`pre-cutover-backup.yml`), then the canonical `production-deploy.yml`. Migration only; no Edge Function or frontend change is required.
3. Read-only production checks: migration version, the five functions, the two triggers, the anchors applied (the migration fails atomically if any live definition drifted), and the reconciliation query above.
