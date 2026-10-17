export function recurrenceOption(value: unknown): boolean {
  if (value === undefined) return false;
  if (typeof value !== "boolean") throw new Error("MARKETING_CAMPAIGN_RECURRENCE_INVALID");
  return value;
}
