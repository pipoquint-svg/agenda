import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}
function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } }) }
function text(value: unknown) { return typeof value === 'string' ? value.trim() : '' }
function uuid(value: unknown, nullable = false): string | null { if (nullable && (value === null || value === undefined || value === '')) return null; const next=text(value); if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) throw new Error('UUID_INVALID'); return next }
function integer(value: unknown, field: string, nullable = false): number | null { if (nullable && (value === null || value === undefined || value === '')) return null; const next=Number(value); if (!Number.isInteger(next)) throw new Error(`${field.toUpperCase()}_INVALID`); return next }
function numeric(value: unknown): number { const next=Number(value); if (!Number.isFinite(next)) throw new Error('COUPON_DISCOUNT_VALUE_INVALID'); return next }
function timestamp(value: unknown): string | null { if (value === null || value === undefined || value === '') return null; const next=text(value); if (!next || Number.isNaN(Date.parse(next))) throw new Error('COUPON_VALIDITY_INVALID'); return new Date(next).toISOString() }
function uuidArray(value: unknown): string[] { if (!Array.isArray(value)) throw new Error('COUPON_SERVICES_INVALID'); return value.map((item)=>uuid(item) as string) }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null,{status:204,headers:corsHeaders})
  if (!['GET','POST','PUT','DELETE'].includes(req.method)) return json({error:{code:'METHOD_NOT_ALLOWED'}},405)
  try {
    const admin=await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId,'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const client=adminClient()
    if (req.method === 'GET') {
      const url=new URL(req.url)
      const couponId=url.searchParams.get('coupon_id')
      if (couponId) {
        const {data,error}=await client.rpc('admin_coupon_usage',{p_coupon_id:uuid(couponId)})
        if (error) throw new Error(error.message)
        return json({usage:data ?? []})
      }
      const [coupons,services,customers,metrics]=await Promise.all([
        client.rpc('admin_list_coupons'),
        client.rpc('service_admin_list_service_settings'),
        client.from('customers').select('id,name,email').eq('customer_type','PERSON').order('name').limit(500),
        client.rpc('admin_coupon_metrics'),
      ])
      if (coupons.error) throw new Error(coupons.error.message)
      if (services.error) throw new Error(services.error.message)
      if (customers.error) throw new Error(customers.error.message)
      if (metrics.error) throw new Error(metrics.error.message)
      return json({coupons:coupons.data ?? [],metrics:metrics.data ?? {},services:(services.data ?? []).map((service:Record<string,unknown>)=>({id:service.id,name:service.name,category_id:service.category_id,category_name:service.category_name,operation_scope:service.operation_scope,is_active:service.is_active})),customers:customers.data ?? []})
    }
    const body=await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('COUPON_PAYLOAD_INVALID')
    if (req.method === 'DELETE') {
      const {data,error}=await client.rpc('admin_remove_coupon_audited',{p_coupon_id:uuid(body.coupon_id),p_admin_id:admin.adminId})
      if (error) throw new Error(error.message); return json(data)
    }
    const args={p_code:text(body.code),p_discount_type:text(body.discount_type).toUpperCase(),p_discount_value:numeric(body.discount_value),p_valid_from:timestamp(body.valid_from),p_valid_until:timestamp(body.valid_until),p_max_uses:integer(body.max_uses,'max_uses',true),p_max_uses_per_customer:integer(body.max_uses_per_customer,'max_uses_per_customer',true),p_customer_id:uuid(body.customer_id,true),p_service_ids:uuidArray(body.service_ids ?? []),p_admin_id:admin.adminId}
    if (req.method === 'POST') { const {data,error}=await client.rpc('admin_create_coupon_audited',args); if(error) throw new Error(error.message); return json(data,201) }
    const {data,error}=await client.rpc('admin_update_coupon_audited',{...args,p_coupon_id:uuid(body.coupon_id),p_is_active:body.is_active !== false})
    if(error) throw new Error(error.message); return json(data)
  } catch(error) {
    const code=error instanceof Error ? error.message.split(':')[0] : 'COUPON_ADMIN_FAILED'
    const status=code.startsWith('ADMIN_AUTH_') || code==='ADMIN_ACCESS_DENIED' ? 401 : code==='ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({error:{code}},status)
  }
})
