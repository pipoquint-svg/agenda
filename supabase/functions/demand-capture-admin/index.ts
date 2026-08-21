import { adminClient, requireAdmin } from '../_shared/supabase.ts'
import { DEMAND_STATUSES } from '../_shared/demand-capture.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PATCH, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function clean(value: string | null): string | null {
  const result = value?.trim() ?? ''
  return result || null
}

function createdBoundary(value: string | null, end = false): string | null {
  const item = clean(value)
  if (!item) return null
  if (/^\d{4}-\d{2}-\d{2}$/.test(item)) {
    if (!end) return `${item}T00:00:00-03:00`
    const date = new Date(`${item}T12:00:00Z`)
    date.setUTCDate(date.getUTCDate() + 1)
    return `${date.toISOString().slice(0, 10)}T00:00:00-03:00`
  }
  const parsed = new Date(item)
  if (Number.isNaN(parsed.getTime())) throw new Error('FILTER_DATE_INVALID')
  return parsed.toISOString()
}

function csvCell(value: unknown): string {
  let text = value === null || value === undefined ? '' : String(value)
  if (/^[=+\-@]/.test(text)) text = `'${text}`
  return `"${text.replaceAll('"', '""')}"`
}

type Filters = {
  brand: string | null
  campaign: string | null
  service: string | null
  createdFrom: string | null
  createdTo: string | null
  desiredFrom: string | null
  desiredTo: string | null
  status: string | null
}

function readFilters(url: URL): Filters {
  const status = clean(url.searchParams.get('status'))
  if (status && !DEMAND_STATUSES.includes(status as typeof DEMAND_STATUSES[number])) {
    throw new Error('STATUS_INVALID')
  }
  return {
    brand: clean(url.searchParams.get('brand')),
    campaign: clean(url.searchParams.get('campaign')),
    service: clean(url.searchParams.get('service')),
    createdFrom: createdBoundary(url.searchParams.get('created_from')),
    createdTo: createdBoundary(url.searchParams.get('created_to'), true),
    desiredFrom: clean(url.searchParams.get('desired_from')),
    desiredTo: clean(url.searchParams.get('desired_to')),
    status,
  }
}

function applyFilters(query: any, filters: Filters) {
  if (filters.brand) query = query.eq('brand', filters.brand)
  if (filters.campaign) query = query.eq('campaign', filters.campaign)
  if (filters.service) query = query.eq('service_label', filters.service)
  if (filters.createdFrom) query = query.gte('created_at', filters.createdFrom)
  if (filters.createdTo) query = query.lt('created_at', filters.createdTo)
  if (filters.desiredFrom) query = query.gte('desired_date', filters.desiredFrom)
  if (filters.desiredTo) query = query.lte('desired_date', filters.desiredTo)
  if (filters.status) query = query.eq('status', filters.status)
  return query
}

async function fetchAllFiltered(client: ReturnType<typeof adminClient>, filters: Filters) {
  const rows: Record<string, unknown>[] = []
  let offset = 0
  while (true) {
    let query = client.from('demand_capture').select('*').order('created_at', { ascending: false })
    query = applyFilters(query, filters).range(offset, offset + 999)
    const { data, error } = await query
    if (error) throw new Error(`DEMAND_LIST_FAILED:${error.message}`)
    const page = (data ?? []) as Record<string, unknown>[]
    rows.push(...page)
    if (page.length < 1000) break
    offset += 1000
  }
  return rows
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'PATCH') {
      const body = await req.json() as Record<string, unknown>
      const id = typeof body.id === 'string' ? body.id : ''
      const status = typeof body.status === 'string' ? body.status : ''
      if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error('ID_INVALID')
      if (!DEMAND_STATUSES.includes(status as typeof DEMAND_STATUSES[number])) throw new Error('STATUS_INVALID')

      const { data, error } = await client
        .from('demand_capture')
        .update({ status, updated_at: new Date().toISOString() })
        .eq('id', id)
        .select('id, status')
        .maybeSingle()
      if (error) throw new Error(`STATUS_UPDATE_FAILED:${error.message}`)
      if (!data) throw new Error('DEMAND_NOT_FOUND')
      return json(data)
    }

    if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

    const url = new URL(req.url)
    const filters = readFilters(url)
    const format = clean(url.searchParams.get('format'))

    if (format === 'csv') {
      const rows = await fetchAllFiltered(client, filters)
      const columns = [
        ['created_at', 'data_registro'],
        ['name', 'nome'],
        ['whatsapp', 'whatsapp'],
        ['email', 'email'],
        ['brand', 'marca'],
        ['service_label', 'servico'],
        ['desired_date', 'data_pretendida'],
        ['desired_period', 'periodo'],
        ['campaign', 'campanha'],
        ['status', 'status'],
      ] as const
      const lines = [
        columns.map(([, label]) => csvCell(label)).join(';'),
        ...rows.map((row) => columns.map(([key]) => csvCell(row[key])).join(';')),
      ]
      return new Response(`\uFEFF${lines.join('\r\n')}`, {
        status: 200,
        headers: {
          ...corsHeaders,
          'content-type': 'text/csv; charset=utf-8',
          'content-disposition': 'attachment; filename="captura-demanda.csv"',
        },
      })
    }

    const page = Math.max(1, Number.parseInt(url.searchParams.get('page') ?? '1', 10) || 1)
    const pageSize = Math.min(100, Math.max(1, Number.parseInt(url.searchParams.get('page_size') ?? '50', 10) || 50))
    const from = (page - 1) * pageSize
    const to = from + pageSize - 1

    let listQuery = client
      .from('demand_capture')
      .select('id, created_at, name, whatsapp, email, brand, service_label, desired_date, desired_period, campaign, status', { count: 'exact' })
      .order('created_at', { ascending: false })
    listQuery = applyFilters(listQuery, filters).range(from, to)

    const [{ data: records, error: listError, count }, summaryResult] = await Promise.all([
      listQuery,
      client.rpc('demand_capture_summary', {
        p_brand: filters.brand,
        p_campaign: filters.campaign,
        p_service_label: filters.service,
        p_created_from: filters.createdFrom,
        p_created_to: filters.createdTo,
        p_desired_from: filters.desiredFrom,
        p_desired_to: filters.desiredTo,
        p_status: filters.status,
      }),
    ])

    if (listError) throw new Error(`DEMAND_LIST_FAILED:${listError.message}`)
    if (summaryResult.error) throw new Error(`DEMAND_SUMMARY_FAILED:${summaryResult.error.message}`)

    return json({
      records: records ?? [],
      pagination: { page, page_size: pageSize, total: count ?? 0 },
      summary: summaryResult.data ?? { total: 0, by_date: [], by_period: [], by_service: [] },
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'DEMAND_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_') ? 401 : 400
    return json({ error: { code } }, status)
  }
})
