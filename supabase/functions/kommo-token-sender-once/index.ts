import "jsr:@supabase/functions-js/edge-runtime.d.ts";

Deno.serve(() => Response.json({ error: "DISABLED" }, { status: 410 }));
