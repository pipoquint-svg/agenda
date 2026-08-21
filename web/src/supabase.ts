import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!url || !publishableKey) {
  throw new Error('Frontend Supabase configuration is missing')
}

export const supabase = createClient(url, publishableKey, {
  auth: { persistSession: true, autoRefreshToken: true },
})

export const functionsBaseUrl = `${url.replace(/\/$/, '')}/functions/v1`
export const publicApiKey = publishableKey
