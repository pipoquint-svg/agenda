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
