import { functionsBaseUrl, publicApiKey } from './supabase'

export type EmployeeWorkRule={id?:string;weekday:number;start_local_time:string;end_local_time:string;slot_interval_minutes:number;is_active:boolean}
export type EmployeeException={id:string;exception_type:'BLOCK'|'OPEN';start_at:string;end_at:string;reason:string|null;created_at:string}
export type EmployeeAssignment={service_employee_id:string;service_id:string;service_name:string;operation_scope:'SABRINA'|'BLACKSHEEP'|null;category_id:string|null;is_active:boolean;work_hours:EmployeeWorkRule[];exceptions:EmployeeException[];write_calendar:{google_calendar_id:string;calendar_name:string;time_scope:string}|null}
export type EmployeeRow={id:string;name:string;email:string|null;phone:string|null;notes:string|null;is_active:boolean;resource_id:string|null;blocking_calendar_ids?:string[];service_assignments:EmployeeAssignment[]}
export type EmployeeService={id:string;name:string;category_id:string|null;category_name:string|null;operation_scope:'SABRINA'|'BLACKSHEEP'|null;is_active:boolean}
export type EmployeeCalendar={id:string;name:string;is_active:boolean;google_connection_id:string;access_role?:string|null;writable?:boolean}
export type EmployeeBundle={employees:EmployeeRow[];services:EmployeeService[];google_calendars:EmployeeCalendar[]}

async function request(accessToken:string,init?:RequestInit):Promise<any>{const res=await fetch(`${functionsBaseUrl}/admin-employees`,{...init,headers:{apikey:publicApiKey,authorization:`Bearer ${accessToken}`,'content-type':'application/json',...(init?.headers??{})}});const body=await res.json().catch(()=>({}));if(!res.ok)throw new Error(body?.error?.code??`HTTP_${res.status}`);return body}
export const loadEmployees=(token:string)=>request(token) as Promise<EmployeeBundle>
export const createEmployee=(input:{name:string;email:string;phone:string;notes:string},token:string)=>request(token,{method:'POST',body:JSON.stringify({action:'CREATE',...input})})
export const updateEmployee=(input:{employee_id:string;name:string;email:string;phone:string;notes:string;is_active:boolean},token:string)=>request(token,{method:'PUT',body:JSON.stringify({action:'UPDATE',...input})})
export const replaceEmployeeServices=(employeeId:string,serviceIds:string[],token:string)=>request(token,{method:'PUT',body:JSON.stringify({action:'SERVICES',employee_id:employeeId,service_ids:serviceIds})})
export const replaceWorkHours=(serviceEmployeeId:string,rules:EmployeeWorkRule[],token:string)=>request(token,{method:'PUT',body:JSON.stringify({action:'WORK_HOURS',service_employee_id:serviceEmployeeId,rules})})
export const addEmployeeException=(input:{service_employee_id:string;exception_type:'BLOCK'|'OPEN';start_at:string;end_at:string;reason:string},token:string)=>request(token,{method:'POST',body:JSON.stringify({action:'EXCEPTION_ADD',...input})})
export const removeEmployeeException=(exceptionId:string,token:string)=>request(token,{method:'DELETE',body:JSON.stringify({action:'EXCEPTION_DELETE',exception_id:exceptionId})})
export const setEmployeeWriteCalendar=(serviceEmployeeId:string,calendarId:string,timeScope:'FULL_APPOINTMENT'|'CORE_ONLY',token:string)=>request(token,{method:'PUT',body:JSON.stringify({action:'WRITE_CALENDAR',service_employee_id:serviceEmployeeId,google_calendar_id:calendarId,time_scope:timeScope})})
export const clearEmployeeWriteCalendar=(serviceEmployeeId:string,token:string)=>request(token,{method:'PUT',body:JSON.stringify({action:'CLEAR_WRITE_CALENDAR',service_employee_id:serviceEmployeeId})})
