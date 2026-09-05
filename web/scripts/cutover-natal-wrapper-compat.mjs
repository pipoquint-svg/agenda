import fs from 'node:fs'

const bundlePath = new URL('../dist/embed/agenda-embed.js', import.meta.url)
const source = fs.readFileSync(bundlePath, 'utf8')

const exactPatterns = [
  ['global name', 'var BlackSheepAgendaEmbed=(function(co)'],
  ['flow mode', 'function W0({slug:a="sabrina"}){const[n,s]=B.useState(null),'],
  ['active step index', 'Fo=jf.indexOf(p)'],
  ['stepper order', 'children:jf.map((C,Q)=>'],
  ['hold timer stages', 'if(!he||!["PEOPLE","CUSTOMER","REVIEW"].includes(p)){X(0);return}'],
  ['hold strip stages', 'he&&["PEOPLE","CUSTOMER","REVIEW"].includes(p)&&G>0?'],
  ['extras preserve hold', 'function Qr(C,Q){$(xe=>({...xe,[C]:Q})),ye(""),Se([]),ze(null),U(null),oe(null),sessionStorage.removeItem("bs_checkout_hold"),m("")}'],
  ['back navigation', 'function Zr(){he||(p==="EXTRAS"&&y("SERVICE"),p==="DATE"&&y("EXTRAS"),p==="PEOPLE"&&y("DATE"))}'],
  ['post hold destination', 'expiresAt:Q.expires_at})),y("PEOPLE")}catch'],
  ['extras hold validation anchor', 'async function St(){'],
  ['service destination', 'disabled:!ce||!E,onClick:()=>y("EXTRAS"),children:"Continuar"'],
  ['extras stage copy', 'f.jsx("small",{children:"Etapa 2"}),f.jsx("h2",{children:"Quer incluir algum extra?"}),f.jsx("p",{children:"Os extras entram no cálculo do tempo antes de mostrarmos as datas disponíveis."})'],
  ['extras actions', 'f.jsxs("div",{className:"sby-actions",children:[f.jsx("button",{className:"sby-secondary",type:"button",onClick:Zr,children:"Voltar"}),f.jsx("button",{className:"sby-primary",type:"button",onClick:()=>y("DATE"),children:"Ver datas"})]})'],
  ['date stage copy', 'f.jsx("small",{children:"Etapa 3"}),f.jsx("h2",{children:"Escolha a data e o horário"}),f.jsx("p",{children:"O calendário já considera o pacote e os extras selecionados."})'],
  ['people options', 'ce.minimum_people===ce.maximum_people?f.jsxs("div",{className:"sby-people-fixed",children:[ce.minimum_people," ",ce.minimum_people===1?"pessoa":"pessoas"]}):f.jsx("div",{className:"sby-people-grid",children:Array.from({length:ce.maximum_people-ce.minimum_people+1},(C,Q)=>ce.minimum_people+Q).map(C=>f.jsxs("button",{type:"button",className:V===C?"selected":"",onClick:()=>ne(C),children:[C,f.jsx("small",{children:C===1?"pessoa":"pessoas"})]},C))})'],
  ['coupon block', 'f.jsxs("div",{className:"sby-review-block",children:[f.jsxs("label",{className:"sby-field",children:[f.jsx("span",{children:"Cupom de desconto"}),f.jsx("input",{value:Y,onChange:C=>te(C.target.value.toUpperCase()),placeholder:"Digite seu cupom",disabled:ue})]}),f.jsx("div",{className:"sby-inline-actions",children:w?.coupon_code?f.jsx("button",{type:"button",onClick:()=>{nu()},disabled:ue,children:"Remover cupom"}):f.jsx("button",{type:"button",onClick:()=>{tu()},disabled:ue||Y.trim().length<3,children:"Aplicar cupom"})})]})'],
]

let failed = false
for (const [label, pattern] of exactPatterns) {
  let count = 0
  let offset = 0
  while ((offset = source.indexOf(pattern, offset)) !== -1) {
    count += 1
    offset += pattern.length
  }
  if (count !== 1) {
    console.error(`NATAL_WRAPPER_PATTERN_MISMATCH:${label}:count=${count}`)
    failed = true
  }
}

for (const host of ['checkout.infinitepay.com.br', 'checkout.infinitepay.io']) {
  if (!source.includes(host)) {
    console.error(`INFINITEPAY_CHECKOUT_HOST_MISSING:${host}`)
    failed = true
  }
}

if (!source.includes('infinitepay-payment')) {
  console.error('INFINITEPAY_PAYMENT_CLIENT_MISSING')
  failed = true
}

if (failed) process.exit(1)
console.log('CUTOVER_NATAL_WRAPPER_COMPAT_OK')
