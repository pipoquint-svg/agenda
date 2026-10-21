# BlackSheep Rewards — campaign catalog (decisions of 2026-10-20)

Product decisions taken by the owner while building the Rewards WhatsApp editor ([agenda#515](https://github.com/pipoquint-svg/agenda/pull/515)). The engine still issues no coupon and sends no message: Rewards issuance and delivery stay frozen until explicitly released.

## Campaigns

| Campaign | Rule | Messages (one set per campaign) | Engine status |
|---|---|---|---|
| Coupon after each rental | Every completed and paid rental releases a coupon valid for 30 days to confirm a new booking. This also covers the second rental. | `REWARDS_COUPON_ISSUED`, `REWARDS_COUPON_EXPIRING` | Trigger `RENTAL_COMPLETED_FINANCIALLY_CLEARED` implemented (S3) |
| Come back after 90 days | A customer with no rental for 90 days receives a 30-day coupon. | `REWARDS_WINBACK`, `REWARDS_COUPON_EXPIRING` | Trigger kind `INACTIVITY` exists in the schema; evaluation not implemented |
| After the free visit | Whoever completed the free studio visit receives a 30-day coupon. | The campaign's own `REWARDS_COUPON_ISSUED` text, `REWARDS_COUPON_EXPIRING` | New trigger needed (visit completed) |
| Referral | See below. | `REWARDS_REFERRAL_CODE`, `REWARDS_REFERRAL_REWARD` | New: personal code + attribution + reward trigger |

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
