import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { triggerOffer } from "./trigger.ts";

Deno.test("defaults to the rental trigger with no rules", () => {
  assertEquals(triggerOffer({}), { trigger_kind: "RENTAL_COMPLETED_FINANCIALLY_CLEARED", trigger_rules: {} });
  assertEquals(triggerOffer({ trigger_kind: "free_visit_completed" }), { trigger_kind: "FREE_VISIT_COMPLETED", trigger_rules: {} });
});

Deno.test("the come-back trigger keeps a 30 to 365 day absence, 90 by default", () => {
  assertEquals(triggerOffer({ trigger_kind: "INACTIVITY" }), { trigger_kind: "INACTIVITY", trigger_rules: { inactivity_days: 90 } });
  assertEquals(triggerOffer({ trigger_kind: "INACTIVITY", inactivity_days: 120 }).trigger_rules, { inactivity_days: 120 });
  assertThrows(() => triggerOffer({ trigger_kind: "INACTIVITY", inactivity_days: 10 }), Error, "MARKETING_CAMPAIGN_INACTIVITY_DAYS_INVALID");
  assertThrows(() => triggerOffer({ trigger_kind: "INACTIVITY", inactivity_days: 90.5 }), Error, "MARKETING_CAMPAIGN_INACTIVITY_DAYS_INVALID");
});

Deno.test("only the supported triggers can be created", () => {
  for (const kind of ["BIRTHDAY", "MANUAL", "CUSTOM", "REFERRAL"]) {
    assertThrows(() => triggerOffer({ trigger_kind: kind }), Error, "MARKETING_CAMPAIGN_TRIGGER_INVALID");
  }
});

Deno.test("the referral trigger carries the friend's discount and a monthly cap", () => {
  assertEquals(
    triggerOffer({ trigger_kind: "REFERRAL_FIRST_RENTAL", referred_discount_type: "percent", referred_discount_value: 10 }),
    { trigger_kind: "REFERRAL_FIRST_RENTAL", trigger_rules: { referred_discount_type: "PERCENT", referred_discount_value: 10, monthly_cap: 5 } },
  );
  assertEquals(
    triggerOffer({ trigger_kind: "REFERRAL_FIRST_RENTAL", referred_discount_type: "FIXED", referred_discount_value: 50.5, monthly_cap: 3 }).trigger_rules,
    { referred_discount_type: "FIXED", referred_discount_value: 50.5, monthly_cap: 3 },
  );
  for (const bad of [
    { referred_discount_type: "PERCENT", referred_discount_value: 0 },
    { referred_discount_type: "PERCENT", referred_discount_value: 120 },
    { referred_discount_type: "OTHER", referred_discount_value: 10 },
    { referred_discount_type: "FIXED", referred_discount_value: 10.555 },
  ]) {
    assertThrows(() => triggerOffer({ trigger_kind: "REFERRAL_FIRST_RENTAL", ...bad }), Error, "MARKETING_CAMPAIGN_REFERRED_DISCOUNT_INVALID");
  }
  assertThrows(
    () => triggerOffer({ trigger_kind: "REFERRAL_FIRST_RENTAL", referred_discount_type: "PERCENT", referred_discount_value: 10, monthly_cap: 0 }),
    Error,
    "MARKETING_CAMPAIGN_MONTHLY_CAP_INVALID",
  );
});
