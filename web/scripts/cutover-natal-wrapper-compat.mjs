import fs from 'node:fs'

const bundlePath = new URL('../dist/embed/agenda-embed.js', import.meta.url)
const source = fs.readFileSync(bundlePath, 'utf8')

function replaceExact(value, from, to, label) {
  const first = value.indexOf(from)
  if (first < 0 || value.indexOf(from, first + from.length) >= 0) {
    throw new Error(`NATAL_WRAPPER_PATTERN_MISMATCH:${label}`)
  }
  return value.replace(from, to)
}

function patchNatalAgendaBundle(input) {
  let patched = input

  patched = replaceExact(
    patched,
    'var BlackSheepAgendaEmbed=(function(fo)',
    'var BlackSheepNatalAgendaEmbed=(function(fo)',
    'global name',
  )

  patched = replaceExact(
    patched,
    'function vS({slug:a="sabrina"}){const[n,s]=M.useState(null),',
    'function vS({slug:a="sabrina"}){const natalFlow=a==="natal-2026",flowSteps=natalFlow?["SERVICE","DATE","EXTRAS","PEOPLE","CUSTOMER","REVIEW","PAYMENT","CONFIRMATION"]:Uf,[n,s]=M.useState(null),',
    'flow mode',
  )

  patched = replaceExact(patched, 'ec=Uf.indexOf(m)', 'ec=flowSteps.indexOf(m)', 'active step index')
  patched = replaceExact(patched, 'children:Uf.map((R,Q)=>', 'children:flowSteps.map((R,Q)=>', 'stepper order')

  patched = replaceExact(
    patched,
    'if(!he||!["PEOPLE","CUSTOMER","REVIEW"].includes(m)){J(0);return}',
    'if(!he||!(natalFlow?["EXTRAS","PEOPLE","CUSTOMER","REVIEW"]:["PEOPLE","CUSTOMER","REVIEW"]).includes(m)){J(0);return}',
    'hold timer stages',
  )

  patched = replaceExact(
    patched,
    'he&&["PEOPLE","CUSTOMER","REVIEW"].includes(m)&&G>0?',
    'he&&(natalFlow?["EXTRAS","PEOPLE","CUSTOMER","REVIEW"]:["PEOPLE","CUSTOMER","REVIEW"]).includes(m)&&G>0?',
    'hold strip stages',
  )

  patched = replaceExact(
    patched,
    'function Fr(R,Q){I(je=>({...je,[R]:Q})),ye(""),Se([]),Ie(null),U(null),oe(null),sessionStorage.removeItem("bs_checkout_hold"),p("")}',
    'function Fr(R,Q){I(je=>({...je,[R]:Q})),natalFlow&&he?p(""):(ye(""),Se([]),Ie(null),U(null),oe(null),sessionStorage.removeItem("bs_checkout_hold"),p(""))}',
    'extras preserve hold',
  )

  patched = replaceExact(
    patched,
    'function Wr(){he||(m==="EXTRAS"&&y("SERVICE"),m==="DATE"&&y("EXTRAS"),m==="PEOPLE"&&y("DATE"))}',
    'function Wr(){he||(natalFlow?(m==="DATE"&&y("SERVICE"),m==="EXTRAS"&&y("DATE"),m==="PEOPLE"&&y("EXTRAS")):(m==="EXTRAS"&&y("SERVICE"),m==="DATE"&&y("EXTRAS"),m==="PEOPLE"&&y("DATE")))}',
    'back navigation',
  )

  patched = replaceExact(
    patched,
    'expiresAt:Q.expires_at})),y("PEOPLE")}catch',
    'expiresAt:Q.expires_at})),y(natalFlow?"EXTRAS":"PEOPLE")}catch',
    'post hold destination',
  )

  patched = replaceExact(
    patched,
    'async function St(){',
    'async function natalConfirmExtras(){if(!he)return;h(!0),p("");try{await oS({token:he.checkout_hold_token,extras:xe,peopleCount:V}),y("PEOPLE")}catch(R){p(On(R));const Q=R instanceof Error?R.message:"";(Q.includes("CHECKOUT_HOLD_NOT_ACTIVE")||Q.includes("HOLD_EXPIRED")||Q.includes("HOLD_SELECTION_REQUIRES_NEW_SLOT")||Q.includes("HOLD_SELECTION_LOCKED"))&&(sessionStorage.removeItem("bs_checkout_hold"),U(null),oe(null),Ie(null),ye(""),Se([]),y("DATE"))}finally{h(!1)}}async function St(){',
    'extras hold validation',
  )

  patched = replaceExact(
    patched,
    'disabled:!ue||!w,onClick:()=>y("EXTRAS"),children:"Continuar"',
    'disabled:!ue||!w,onClick:()=>y(natalFlow?"DATE":"EXTRAS"),children:"Continuar"',
    'service destination',
  )

  patched = replaceExact(
    patched,
    'f.jsx("small",{children:"Etapa 2"}),f.jsx("h2",{children:"Quer incluir algum extra?"}),f.jsx("p",{children:"Os extras entram no cálculo do tempo antes de mostrarmos as datas disponíveis."})',
    'f.jsx("small",{children:natalFlow?"Etapa 3":"Etapa 2"}),f.jsx("h2",{children:"Quer incluir algum extra?"}),f.jsx("p",{children:natalFlow?"Seu horário já está protegido. Escolha os extras e vamos validar tudo antes de continuar.":"Os extras entram no cálculo do tempo antes de mostrarmos as datas disponíveis."})',
    'extras stage copy',
  )

  patched = replaceExact(
    patched,
    'f.jsxs("div",{className:"sby-actions",children:[f.jsx("button",{className:"sby-secondary",type:"button",onClick:Wr,children:"Voltar"}),f.jsx("button",{className:"sby-primary",type:"button",onClick:()=>y("DATE"),children:"Ver datas"})]})',
    'natalFlow?f.jsx("div",{className:"sby-actions end",children:f.jsx("button",{className:"sby-primary",type:"button",disabled:d,onClick:()=>{natalConfirmExtras()},children:d?"Validando…":"Continuar"})}):f.jsxs("div",{className:"sby-actions",children:[f.jsx("button",{className:"sby-secondary",type:"button",onClick:Wr,children:"Voltar"}),f.jsx("button",{className:"sby-primary",type:"button",onClick:()=>y("DATE"),children:"Ver datas"})]})',
    'extras actions',
  )

  patched = replaceExact(
    patched,
    'f.jsx("small",{children:"Etapa 3"}),f.jsx("h2",{children:"Escolha a data e o horário"}),f.jsx("p",{children:"O calendário já considera o pacote e os extras selecionados."})',
    'f.jsx("small",{children:natalFlow?"Etapa 2":"Etapa 3"}),f.jsx("h2",{children:"Escolha a data e o horário"}),f.jsx("p",{children:natalFlow?"Escolha primeiro o melhor horário. Os extras serão definidos na próxima etapa.":"O calendário já considera o pacote e os extras selecionados."})',
    'date stage copy',
  )

  const standardPeople = 'ue.minimum_people===ue.maximum_people?f.jsxs("div",{className:"sby-people-fixed",children:[ue.minimum_people," ",ue.minimum_people===1?"pessoa":"pessoas"]}):f.jsx("div",{className:"sby-people-grid",children:Array.from({length:ue.maximum_people-ue.minimum_people+1},(R,Q)=>ue.minimum_people+Q).map(R=>f.jsxs("button",{type:"button",className:V===R?"selected":"",onClick:()=>ne(R),children:[R,f.jsx("small",{children:R===1?"pessoa":"pessoas"})]},R))})'
  patched = replaceExact(
    patched,
    standardPeople,
    'natalFlow&&Array.isArray(ue.people_options)&&ue.people_options.length>0?f.jsx("div",{className:"sby-people-grid",children:ue.people_options.map(R=>f.jsxs("button",{type:"button",className:V===R.count?"selected":"",onClick:()=>ne(R.count),children:[R.count,f.jsx("small",{children:R.included?(R.count===1?"pessoa · incluída":"pessoas · incluídas"):`+ ${As.format(pi(R.extra_people_amount))}`})]},R.count))}):' + standardPeople,
    'people options',
  )

  const couponBlock = 'f.jsxs("div",{className:"sby-review-block",children:[f.jsxs("label",{className:"sby-field",children:[f.jsx("span",{children:"Cupom de desconto"}),f.jsx("input",{value:Y,onChange:R=>te(R.target.value.toUpperCase()),placeholder:"Digite seu cupom",disabled:ce})]}),f.jsx("div",{className:"sby-inline-actions",children:E?.coupon_code?f.jsx("button",{type:"button",onClick:()=>{ic()},disabled:ce,children:"Remover cupom"}):f.jsx("button",{type:"button",onClick:()=>{ac()},disabled:ce||Y.trim().length<3,children:"Aplicar cupom"})})]})'
  patched = replaceExact(patched, couponBlock, 'natalFlow?null:' + couponBlock, 'coupon hidden on Natal')

  if (patched.includes('disponível${ge.length===1?"":"is"}')) {
    patched = patched.replace('disponível${ge.length===1?"":"is"}', 'disponíve${ge.length===1?"l":"is"}')
  }

  return patched
}

for (const host of ['checkout.infinitepay.com.br', 'checkout.infinitepay.io']) {
  if (!source.includes(host)) throw new Error(`INFINITEPAY_CHECKOUT_HOST_MISSING:${host}`)
}
if (!source.includes('infinitepay-payment')) throw new Error('INFINITEPAY_PAYMENT_CLIENT_MISSING')

const patched = patchNatalAgendaBundle(source)
if (!patched.includes('BlackSheepNatalAgendaEmbed')) throw new Error('NATAL_GLOBAL_MISSING')
if (!patched.includes('natalFlow=a==="natal-2026"')) throw new Error('NATAL_FLOW_SWITCH_MISSING')

// Compile only; do not execute browser code in Node.
new Function(patched)

console.log('CUTOVER_NATAL_WRAPPER_COMPAT_OK')
