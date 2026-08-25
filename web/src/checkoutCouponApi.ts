import { functionsBaseUrl,publicApiKey } from './supabase'
export type CheckoutCouponState={coupon_code:string|null;subtotal:number|string;coupon_discount:number|string;commercial_value:number|string;customer_validation_pending?:boolean}
async function call<T>(action:string,token:string,couponCode?:string):Promise<T>{const res=await fetch(`${functionsBaseUrl}/booking-checkout`,{method:'POST',headers:{'content-type':'application/json',apikey:publicApiKey,authorization:`Bearer ${publicApiKey}`},body:JSON.stringify({action,checkout_hold_token:token,...(couponCode!==undefined?{coupon_code:couponCode}:{})})});const payload=await res.json().catch(()=>({})) as {data?:T;error?:{code?:string}};if(!res.ok||payload.data===undefined)throw new Error(payload.error?.code??`HTTP_${res.status}`);return payload.data}
export const loadCheckoutCoupon=(token:string)=>call<CheckoutCouponState>('COUPON_STATE',token)
export const applyCheckoutCoupon=(token:string,code:string)=>call<CheckoutCouponState>('APPLY_COUPON',token,code)
export const clearCheckoutCoupon=(token:string)=>call<CheckoutCouponState>('CLEAR_COUPON',token)
