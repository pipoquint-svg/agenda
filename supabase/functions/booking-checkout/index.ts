import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}
function response(body: unknown, status = 200): Response { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } }) }
function token(value: unknown, code: string): string { if (typeof value !== 'string' || value.trim().length < 32) throw new Error(code); return value.trim() }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null,{status:204,headers:corsHeaders})
  if (req.method !== 'POST') return response({error:{code:'METHOD_NOT_ALLOWED'}},405)
  try {
    const client=adminClient()
    await enforceDistributedPublicRateLimit(client,req,{scope:'CHECKOUT_TOKEN',limit:30,windowSeconds:600})
    const body=await req.json();const action=typeof body?.action==='string'?body.action.trim().toUpperCase():''
    let rpcName='';let args:Record<string,unknown>={}
    switch(action){
      case 'CONTEXT': rpcName='public_get_checkout_context';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      case 'PREBOOK_OPTION':rpcName='service_public_get_checkout_prebook_option';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      case 'COUPON_STATE': rpcName='get_checkout_coupon_state';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      case 'APPLY_COUPON': rpcName='apply_checkout_coupon';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED'),p_coupon_code:typeof body?.coupon_code==='string'?body.coupon_code:''};break
      case 'CLEAR_COUPON': rpcName='clear_checkout_coupon';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      case 'UPDATE_SELECTION':{const peopleCount=Number.isInteger(body?.people_count)?body.people_count as number:NaN;if(!Number.isInteger(peopleCount))throw new Error('INVALID_PEOPLE_COUNT');rpcName='public_update_checkout_hold_selection';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED'),p_extra_selections:Array.isArray(body?.extra_selections)?body.extra_selections:[],p_people_count:peopleCount};break}
      case 'BIND_CUSTOMER':rpcName='public_bind_checkout_customer';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED'),p_name:typeof body?.name==='string'?body.name:'',p_email:typeof body?.email==='string'?body.email:'',p_phone:typeof body?.phone==='string'?body.phone:'',p_tax_id:typeof body?.tax_id==='string'&&body.tax_id.trim()?body.tax_id.trim():null,p_recovery_enabled:false};break
      case 'LIST_PACKAGES':rpcName='public_list_checkout_hour_packages';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      case 'SELECT_PACKAGE':rpcName='public_select_checkout_hour_package';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED'),p_hour_package_id:typeof body?.hour_package_id==='string'?body.hour_package_id:''};break
      case 'CLEAR_PACKAGE':rpcName='public_clear_checkout_hour_package';args={p_checkout_hold_token:token(body?.checkout_hold_token,'CHECKOUT_HOLD_TOKEN_REQUIRED')};break
      default:throw new Error('CHECKOUT_ACTION_INVALID')
    }
    const{data,error}=await client.rpc(rpcName,args);if(error)throw new Error(error.message);return response({data})
  } catch(error) {
    const code=error instanceof Error?error.message:'CHECKOUT_ACTION_FAILED'
    const publicCode=code.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|CHECKOUT_ACTION_INVALID|CHECKOUT_HOLD_TOKEN_REQUIRED|CHECKOUT_HOLD_NOT_ACTIVE|CHECKOUT_HOLD_NOT_FOUND|CHECKOUT_CUSTOMER_REQUIRED|CHECKOUT_CUSTOMER_MISSING|PREBOOK_NOT_AVAILABLE|CUSTOMER_NAME_INVALID|CUSTOMER_EMAIL_INVALID|CUSTOMER_PHONE_INVALID|CUSTOMER_TAX_ID_INVALID|CUSTOMER_IDENTITY_AMBIGUOUS|CUSTOMER_IDENTITY_CONFLICT|INVALID_PEOPLE_COUNT|INVALID_EXTRA_SELECTION|REQUIRED_EXTRA_MISSING|HOLD_SELECTION_UPDATE_NOT_ALLOWED|HOLD_SELECTION_LOCKED|HOLD_SELECTION_REQUIRES_NEW_SLOT|RESOURCE_NOT_AVAILABLE|SERVICE_HAS_NO_REQUIRED_RESOURCES|HOUR_PACKAGE_NOT_FOUND|HOUR_PACKAGE_NOT_USABLE|HOUR_PACKAGE_INSUFFICIENT_BALANCE|INVALID_COUPON|COUPON_USAGE_LIMIT_REACHED|COUPON_CUSTOMER_MISMATCH|COUPON_CUSTOMER_USAGE_LIMIT_REACHED|COUPON_PACKAGE_POLICY_REQUIRES_DECISION|HOLD_NOT_FOUND|HOLD_EXPIRED)/)?.[1]??code.split(':')[0]
    const status=publicCode==='RATE_LIMITED'?429:publicCode==='RATE_LIMIT_BACKEND_FAILED'?503:['CHECKOUT_HOLD_NOT_ACTIVE','RESOURCE_NOT_AVAILABLE','HOLD_SELECTION_REQUIRES_NEW_SLOT','COUPON_USAGE_LIMIT_REACHED','COUPON_CUSTOMER_USAGE_LIMIT_REACHED'].includes(publicCode)?409:400
    return response({error:{code:publicCode}},status)
  }
})
