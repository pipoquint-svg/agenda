# BlackSheep Rewards — campaign catalog (decisions of 2026-10-20)

Product decisions taken by the owner while building the Rewards WhatsApp editor ([agenda#515](https://github.com/pipoquint-svg/agenda/pull/515)). The engine still issues no coupon and sends no message: Rewards issuance and delivery stay frozen until explicitly released.

## Campaigns

| Campaign | Rule | Messages (one set per campaign) | Engine status |
|---|---|---|---|
| Coupon after each rental | Every completed and paid rental releases a coupon valid for 30 days to confirm a new booking. This also covers the second rental. | `REWARDS_COUPON_ISSUED`, `REWARDS_COUPON_EXPIRING` | Implemented (S3; realized rule and legacy fallback since 2026-10-21) |
| Come back after 90 days | A customer with no rental for 90 days receives a 30-day coupon. | `REWARDS_WINBACK`, `REWARDS_COUPON_EXPIRING` | Implemented 2026-10-21: customer-anchored evaluator, candidate list, issuance |
| After the free visit | Whoever completed the free studio visit receives a 30-day coupon. | The campaign's own `REWARDS_COUPON_ISSUED` text, `REWARDS_COUPON_EXPIRING` | Implemented 2026-10-21: `FREE_VISIT_COMPLETED` |
| Referral | See below. | `REWARDS_REFERRAL_CODE`, `REWARDS_REFERRAL_REWARD` | Implemented 2026-10-21: `REFERRAL_FIRST_RENTAL`, personal code, checkout rule |

Not now: off-season or idle-slot coupons, upgrade to half day, loyalty by accumulated hours.

## Referral program: both sides win
1. Each customer who has rented gets a personal referral code to share.
2. The referred friend uses the code and gets a discount on their **first** rental.
3. When that first rental is completed and paid, the referrer receives a 30-day coupon.

Guards for the engine PR:
- the code only works for someone who never rented (match CPF, phone and e-mail);
- no self-referral;
- the referrer's reward only after the friend's rental is paid;
- a monthly cap on referral rewards.

## Message variables
`customer.name`, `customer.last_rental_at`, `campaign.name`, `coupon.code`, `coupon.discount`, `coupon.expires_at`, `coupon.days_left`, `referral.code`, `referral.referred_name`, `operation.name`, `operation.site_url`, `booking.url`.

## Engine rules (decisions of 2026-10-21)
- **Realized** means COMPLETED, or CONFIRMED with its scheduled end in the past (same rule as finance). Production never marks reservations COMPLETED today, so the rental trigger uses this rule too.
- **Reservations without the S3 snapshot** (almost all before 2026-10-16) are classified by the service as registered today. Free visits (`booking_product_type = FREE_VISIT`) are never rentals.
- **Come back after 90 days** is anchored on the customer:
  - the last rental is the latest realized BlackSheep rental in the Agenda or in the linked Amelia history (`matched_customer_id`);
  - no coupon if the customer has a booking ahead or is anonymized;
  - one coupon per absence.

  The absence window comes from `trigger_rules.inactivity_days`: 30 to 365, default 90.
- **After the visit:** the visit must be realized and the customer must never have rented; one coupon per customer and campaign.
- `service_list_marketing_campaign_candidates` lists who would receive the coupon now. It is read-only and no job calls it yet.

Delivery stays frozen: nothing issues coupons or sends messages until it is explicitly released.

## Referral engine (2026-10-21)
- **The code:** `service_ensure_marketing_referral_code(campaign, customer)` creates `IND-XXXXXX`, a shareable coupon with no customer binding. It is created only for a customer who has rented, once per referral campaign. Its discount is the friend's (`trigger_rules.referred_discount_type/value`); it can be used once per customer, on the campaign services, until the campaign ends.
- **The checkout rule:** `coupon_referral_violation` runs in both checkout guards: the online hold and the reservation made in Gestão. It refuses the referrer (same customer, phone or CPF/CNPJ; e-mails are already unique) and anyone with another rental (done, booked or being paid) in the Agenda or Amelia. The reservation using the code does not count against the friend.
- **The reward:** the `REFERRAL_FIRST_RENTAL` campaign's own discount. It is issued through S4 from the friend's realized and paid first rental, to the referrer. One reward per referred rental, capped per month (`trigger_rules.monthly_cap`, 1-50, default 5, São Paulo calendar month).
- Codes are recorded in `marketing_referral_codes` with an audit event `REFERRAL_CODE_CREATED`.

## Editing and deleting campaigns (2026-10-21)
- **Edit:** the name, public name and description change in place. A new offer (trigger, discount, services, validity) becomes a new version; earlier versions stay as history. The offer of an active or scheduled campaign cannot change: pause it first. A paused campaign keeps its published version until it is resumed, which publishes the new one.
- **Delete:** a draft that was never activated, issued nothing, has no referral code and sent no message to Meta is removed, together with its message drafts; a snapshot stays in `audit_logs`. Any other campaign is archived, so coupons already issued keep working and the history is preserved.

## Coupon dispatch after the reservation (2026-10-21)
The "Cupom Rewards liberado" message uses the same scheduled path as the rental balance message:
- **When:** N minutes after the reservation ends (`AFTER_END`, 1 to 1440 minutes), set on the message in Gestão. No other Rewards message has a reservation trigger.
- **What happens:** `whatsapp-send` checks everything that could stop the message (message on, approved by Meta and unchanged, campaign active, valid phone, WhatsApp connected). Then it issues the campaign coupon (S4, one per campaign and reservation) and sends it in the same step. No message, no coupon.
- **Unpaid:** the message waits. When a reservation that already ended becomes PAID within 7 days, it is queued again right away.
- **Changed reservations:** a change does not matter. Issuance and delivery are keyed on the reservation, not its version; a moved reservation is sent after its new end.
- **Campaigns:** only campaigns given by a reservation (after each rental, after the visit). Win-back and referral are not sent this way yet.
- **Switches:** the message's on/off switch in Gestão, the campaign state, and `WHATSAPP_CUSTOMER_DISPATCH_ENABLED`.
