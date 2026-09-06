from pathlib import Path

path = Path('web/src/SabrinaBookingJourney.tsx')
source = path.read_text()


def replace_once(old: str, new: str, label: str):
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly 1 match, found {count}')
    source = source.replace(old, new, 1)


replace_once(
    "type AnswerValue = string | number | boolean | null\n",
    "type AnswerValue = string | number | boolean | null\n"
    "type BookingPeopleOption = { count: number; included: boolean; extra_people_amount: number | string }\n",
    'people option type',
)

replace_once(
    "export function SabrinaBookingJourney({ slug = 'sabrina' }: { slug?: string }) {\n",
    "export function SabrinaBookingJourney({ slug = 'sabrina' }: { slug?: string }) {\n"
    "  const natalFlow = slug === 'natal-2026'\n"
    "  const flowSteps: StepKey[] = natalFlow\n"
    "    ? ['SERVICE', 'DATE', 'EXTRAS', 'PEOPLE', 'CUSTOMER', 'REVIEW', 'PAYMENT', 'CONFIRMATION']\n"
    "    : STEPS\n"
    "  const holdSteps: StepKey[] = natalFlow\n"
    "    ? ['EXTRAS', 'PEOPLE', 'CUSTOMER', 'REVIEW']\n"
    "    : ['PEOPLE', 'CUSTOMER', 'REVIEW']\n",
    'natal mode declaration',
)

replace_once(
    "  const extras = useMemo(() => selectedExtras(service, extraQuantities), [service, extraQuantities])\n  const stepIndex = STEPS.indexOf(step)\n",
    "  const extras = useMemo(() => selectedExtras(service, extraQuantities), [service, extraQuantities])\n"
    "  const peopleOptions = useMemo(() => {\n"
    "    if (!natalFlow || !service) return [] as BookingPeopleOption[]\n"
    "    const options = (service as BookingService & { people_options?: BookingPeopleOption[] }).people_options\n"
    "    return Array.isArray(options) ? options : []\n"
    "  }, [natalFlow, service])\n"
    "  const stepIndex = flowSteps.indexOf(step)\n",
    'step index and people options',
)

replace_once(
    "    if (!hold || !['PEOPLE', 'CUSTOMER', 'REVIEW'].includes(step)) {\n",
    "    if (!hold || !holdSteps.includes(step)) {\n",
    'hold timer stages',
)

replace_once(
    "  function changeExtra(extraId: string, quantity: number) {\n"
    "    setExtraQuantities((current) => ({ ...current, [extraId]: quantity }))\n"
    "    setDate('')\n"
    "    setSlots([])\n"
    "    setSelectedSlot(null)\n"
    "    setHold(null)\n"
    "    setContext(null)\n"
    "    sessionStorage.removeItem('bs_checkout_hold')\n"
    "    setError('')\n"
    "  }\n",
    "  function changeExtra(extraId: string, quantity: number) {\n"
    "    setExtraQuantities((current) => ({ ...current, [extraId]: quantity }))\n"
    "    if (natalFlow && hold) {\n"
    "      setError('')\n"
    "      return\n"
    "    }\n"
    "    setDate('')\n"
    "    setSlots([])\n"
    "    setSelectedSlot(null)\n"
    "    setHold(null)\n"
    "    setContext(null)\n"
    "    sessionStorage.removeItem('bs_checkout_hold')\n"
    "    setError('')\n"
    "  }\n",
    'extras preserve Natal hold',
)

replace_once(
    "  function goBack() {\n"
    "    if (hold) return\n"
    "    if (step === 'EXTRAS') setStep('SERVICE')\n"
    "    if (step === 'DATE') setStep('EXTRAS')\n"
    "    if (step === 'PEOPLE') setStep('DATE')\n"
    "  }\n",
    "  function goBack() {\n"
    "    if (hold) return\n"
    "    if (natalFlow) {\n"
    "      if (step === 'DATE') setStep('SERVICE')\n"
    "      if (step === 'EXTRAS') setStep('DATE')\n"
    "      if (step === 'PEOPLE') setStep('EXTRAS')\n"
    "      return\n"
    "    }\n"
    "    if (step === 'EXTRAS') setStep('SERVICE')\n"
    "    if (step === 'DATE') setStep('EXTRAS')\n"
    "    if (step === 'PEOPLE') setStep('DATE')\n"
    "  }\n",
    'back navigation',
)

replace_once(
    "      setStep('PEOPLE')\n    } catch (cause) {\n      setSelectedSlot(null)\n",
    "      setStep(natalFlow ? 'EXTRAS' : 'PEOPLE')\n    } catch (cause) {\n      setSelectedSlot(null)\n",
    'post hold destination',
)

marker = "  async function confirmPeopleAndContinue() {\n"
if source.count(marker) != 1:
    raise SystemExit('confirm people marker mismatch')
natal_confirm = """  async function confirmNatalExtrasAndContinue() {
    if (!hold) return
    setBusy(true)
    setError('')
    try {
      await updateCheckoutSelection({
        token: hold.checkout_hold_token,
        extras,
        peopleCount,
      })
      setStep('PEOPLE')
    } catch (cause) {
      setError(readableError(cause))
      const message = cause instanceof Error ? cause.message : ''
      if (message.includes('CHECKOUT_HOLD_NOT_ACTIVE') || message.includes('HOLD_EXPIRED') || message.includes('HOLD_SELECTION_REQUIRES_NEW_SLOT') || message.includes('HOLD_SELECTION_LOCKED')) {
        sessionStorage.removeItem('bs_checkout_hold')
        setHold(null)
        setContext(null)
        setSelectedSlot(null)
        setStep('DATE')
      }
    } finally {
      setBusy(false)
    }
  }

"""
source = source.replace(marker, natal_confirm + marker, 1)

replace_once("          {STEPS.map((item, index) => {\n", "          {flowSteps.map((item, index) => {\n", 'stepper order')
replace_once("        {hold && ['PEOPLE', 'CUSTOMER', 'REVIEW'].includes(step) && remainingSeconds > 0 ? (\n", "        {hold && holdSteps.includes(step) && remainingSeconds > 0 ? (\n", 'hold strip stages')

replace_once(
    "onClick={() => setStep('EXTRAS')}>Continuar</button>",
    "onClick={() => setStep(natalFlow ? 'DATE' : 'EXTRAS')}>Continuar</button>",
    'service destination',
)

replace_once(
    '<div className="sby-stage-title"><small>Etapa 2</small><h2>Quer incluir algum extra?</h2><p>Os extras entram no cálculo do tempo antes de mostrarmos as datas disponíveis.</p></div>',
    '<div className="sby-stage-title"><small>{natalFlow ? \'Etapa 3\' : \'Etapa 2\'}</small><h2>Quer incluir algum extra?</h2><p>{natalFlow ? \'Seu horário já está protegido. Escolha os extras e vamos validar tudo antes de continuar.\' : \'Os extras entram no cálculo do tempo antes de mostrarmos as datas disponíveis.\'}</p></div>',
    'extras stage copy',
)

replace_once(
    '<div className="sby-actions"><button className="sby-secondary" type="button" onClick={goBack}>Voltar</button><button className="sby-primary" type="button" onClick={() => setStep(\'DATE\')}>Ver datas</button></div>',
    """{natalFlow ? (
                <div className="sby-actions end"><button className="sby-primary" type="button" disabled={busy} onClick={() => void confirmNatalExtrasAndContinue()}>{busy ? 'Validando…' : 'Continuar'}</button></div>
              ) : (
                <div className="sby-actions"><button className="sby-secondary" type="button" onClick={goBack}>Voltar</button><button className="sby-primary" type="button" onClick={() => setStep('DATE')}>Ver datas</button></div>
              )}""",
    'extras actions',
)

replace_once(
    '<div className="sby-stage-title"><small>Etapa 3</small><h2>Escolha a data e o horário</h2><p>O calendário já considera o pacote e os extras selecionados.</p></div>',
    '<div className="sby-stage-title"><small>{natalFlow ? \'Etapa 2\' : \'Etapa 3\'}</small><h2>Escolha a data e o horário</h2><p>{natalFlow ? \'Escolha primeiro o melhor horário. Os extras serão definidos na próxima etapa.\' : \'O calendário já considera o pacote e os extras selecionados.\'}</p></div>',
    'date stage copy',
)

replace_once(
    "<small>{loadingSlots ? 'Buscando horários…' : `${slots.length} horário${slots.length === 1 ? '' : 's'} disponível${slots.length === 1 ? '' : 'is'}`}</small>",
    "<small>{loadingSlots ? 'Buscando horários…' : `${slots.length} horário${slots.length === 1 ? '' : 's'} ${slots.length === 1 ? 'disponível' : 'disponíveis'}`}</small>",
    'availability grammar',
)

old_people = """              {service.minimum_people === service.maximum_people ? (
                <div className="sby-people-fixed">{service.minimum_people} {service.minimum_people === 1 ? 'pessoa' : 'pessoas'}</div>
              ) : (
                <div className="sby-people-grid">
                  {Array.from({ length: service.maximum_people - service.minimum_people + 1 }, (_, index) => service.minimum_people + index).map((value) => (
                    <button type="button" key={value} className={peopleCount === value ? 'selected' : ''} onClick={() => setPeopleCount(value)}>{value}<small>{value === 1 ? 'pessoa' : 'pessoas'}</small></button>
                  ))}
                </div>
              )}
"""
new_people = """              {peopleOptions.length > 0 ? (
                <div className="sby-people-grid">
                  {peopleOptions.map((option) => (
                    <button type="button" key={option.count} className={peopleCount === option.count ? 'selected' : ''} onClick={() => setPeopleCount(option.count)}>
                      {option.count}
                      <small>{option.included ? (option.count === 1 ? 'pessoa · incluída' : 'pessoas · incluídas') : `+ ${money.format(numeric(option.extra_people_amount))}`}</small>
                    </button>
                  ))}
                </div>
              ) : service.minimum_people === service.maximum_people ? (
                <div className="sby-people-fixed">{service.minimum_people} {service.minimum_people === 1 ? 'pessoa' : 'pessoas'}</div>
              ) : (
                <div className="sby-people-grid">
                  {Array.from({ length: service.maximum_people - service.minimum_people + 1 }, (_, index) => service.minimum_people + index).map((value) => (
                    <button type="button" key={value} className={peopleCount === value ? 'selected' : ''} onClick={() => setPeopleCount(value)}>{value}<small>{value === 1 ? 'pessoa' : 'pessoas'}</small></button>
                  ))}
                </div>
              )}
"""
replace_once(old_people, new_people, 'Natal people options')

old_coupon = """              <div className="sby-review-block">
                <label className="sby-field"><span>Cupom de desconto</span><input value={couponCode} onChange={(event) => setCouponCode(event.target.value.toUpperCase())} placeholder="Digite seu cupom" disabled={couponBusy} /></label>
                <div className="sby-inline-actions">{coupon?.coupon_code ? <button type="button" onClick={() => void removeCoupon()} disabled={couponBusy}>Remover cupom</button> : <button type="button" onClick={() => void applyCoupon()} disabled={couponBusy || couponCode.trim().length < 3}>Aplicar cupom</button>}</div>
              </div>
"""
new_coupon = """              {!natalFlow ? <div className="sby-review-block">
                <label className="sby-field"><span>Cupom de desconto</span><input value={couponCode} onChange={(event) => setCouponCode(event.target.value.toUpperCase())} placeholder="Digite seu cupom" disabled={couponBusy} /></label>
                <div className="sby-inline-actions">{coupon?.coupon_code ? <button type="button" onClick={() => void removeCoupon()} disabled={couponBusy}>Remover cupom</button> : <button type="button" onClick={() => void applyCoupon()} disabled={couponBusy || couponCode.trim().length < 3}>Aplicar cupom</button>}</div>
              </div> : null}
"""
replace_once(old_coupon, new_coupon, 'hide coupon on Natal')

path.write_text(source)

embed = Path('web/src/embed.tsx')
embed_source = embed.read_text()
old = """        {slug === 'sabrina' ? (
          <SabrinaBookingJourney slug={slug} />
        ) : (
"""
new = """        {slug === 'sabrina' || slug === 'natal-2026' ? (
          <SabrinaBookingJourney slug={slug} />
        ) : (
"""
if embed_source.count(old) != 1:
    raise SystemExit(f'embed route: expected 1 match, found {embed_source.count(old)}')
embed.write_text(embed_source.replace(old, new, 1))
