// Production entrypoint for the unified notification platform.
// The active notification templates and their audience/scope rules are authoritative.
// Keep the legacy global switch enabled here so legitimate Agenda events are not
// silently skipped before template resolution and delivery logging.
Deno.env.set('TRANSACTIONAL_EMAIL_ENABLED', 'true')
await import('./index.ts')
