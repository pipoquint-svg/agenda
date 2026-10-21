/** When the customer earns the coupon. */
export const TRIGGER_KINDS = [
  "RENTAL_COMPLETED_FINANCIALLY_CLEARED",
  "INACTIVITY",
  "FREE_VISIT_COMPLETED",
  "REFERRAL_FIRST_RENTAL",
];

function blank(value: unknown) {
  return value === undefined || value === null || value === "";
}

export function triggerOffer(body: Record<string, unknown>) {
  const triggerKind = (typeof body.trigger_kind === "string" ? body.trigger_kind.trim() : "").toUpperCase() ||
    "RENTAL_COMPLETED_FINANCIALLY_CLEARED";
  if (!TRIGGER_KINDS.includes(triggerKind)) {
    throw new Error("MARKETING_CAMPAIGN_TRIGGER_INVALID");
  }
  if (triggerKind === "INACTIVITY") {
    const days = blank(body.inactivity_days) ? 90 : Number(body.inactivity_days);
    if (!Number.isInteger(days) || days < 30 || days > 365) {
      throw new Error("MARKETING_CAMPAIGN_INACTIVITY_DAYS_INVALID");
    }
    return { trigger_kind: triggerKind, trigger_rules: { inactivity_days: days } };
  }
  if (triggerKind === "REFERRAL_FIRST_RENTAL") {
    // The campaign discount is the referrer's reward; the friend's discount rides on the code.
    const type = (typeof body.referred_discount_type === "string" ? body.referred_discount_type.trim() : "").toUpperCase();
    const value = Number(body.referred_discount_value);
    if (!["PERCENT", "FIXED"].includes(type) || !Number.isFinite(value) || value <= 0 || (type === "PERCENT" && value > 100) ||
      Math.round(value * 100) !== value * 100) {
      throw new Error("MARKETING_CAMPAIGN_REFERRED_DISCOUNT_INVALID");
    }
    const cap = blank(body.monthly_cap) ? 5 : Number(body.monthly_cap);
    if (!Number.isInteger(cap) || cap < 1 || cap > 50) {
      throw new Error("MARKETING_CAMPAIGN_MONTHLY_CAP_INVALID");
    }
    return {
      trigger_kind: triggerKind,
      trigger_rules: { referred_discount_type: type, referred_discount_value: value, monthly_cap: cap },
    };
  }
  return { trigger_kind: triggerKind, trigger_rules: {} };
}
