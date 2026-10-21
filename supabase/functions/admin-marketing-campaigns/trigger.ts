/** When the customer earns the coupon. */
export const TRIGGER_KINDS = [
  "RENTAL_COMPLETED_FINANCIALLY_CLEARED",
  "INACTIVITY",
  "FREE_VISIT_COMPLETED",
];

export function triggerOffer(body: Record<string, unknown>) {
  const triggerKind = (typeof body.trigger_kind === "string" ? body.trigger_kind.trim() : "").toUpperCase() ||
    "RENTAL_COMPLETED_FINANCIALLY_CLEARED";
  if (!TRIGGER_KINDS.includes(triggerKind)) {
    throw new Error("MARKETING_CAMPAIGN_TRIGGER_INVALID");
  }
  if (triggerKind !== "INACTIVITY") {
    return { trigger_kind: triggerKind, trigger_rules: {} };
  }
  const days = body.inactivity_days === undefined || body.inactivity_days === null ||
      body.inactivity_days === ""
    ? 90
    : Number(body.inactivity_days);
  if (!Number.isInteger(days) || days < 30 || days > 365) {
    throw new Error("MARKETING_CAMPAIGN_INACTIVITY_DAYS_INVALID");
  }
  return { trigger_kind: triggerKind, trigger_rules: { inactivity_days: days } };
}
