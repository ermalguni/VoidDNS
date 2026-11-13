import { useEffect, useRef, useState, type ReactNode } from 'react';
import { Alert, Badge, Button, Checkbox, Group, Select, Skeleton, Stack, Table, Text, TextInput, Title, Tooltip } from '@mantine/core';
import { useIsFetching, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useSearchParams } from 'react-router-dom';
import { useApi, type Schema } from '../api';
import { ErrorNotice } from '../components';
import { DomainLink, Memberships, useMemberships } from '../DomainInspection';

const outcomes = ['blocked', 'cached', 'forwarded', 'local', 'rejected'] as const;
type Counts = Schema<'MetricCounts'>;
type Summary = Schema<'MetricsSummary'>;
type Client = Schema<'Client'>;
type Request = Schema<'RequestHistoryEntry'>;
type Bucket = Schema<'MetricBucket'>;
type Envelope<T> = { from_ms: number; to_ms: number; observed_at_ms: number; interval_ms: number; data: T; next: string | null };
type Health = Schema<'TelemetryHealth'>;
const number = new Intl.NumberFormat();
const percent = (value: number) => `${value.toFixed(1)}%`;
const date = (value: number) => new Date(value).toLocaleString();
const colors: Record<string, string> = { blocked: 'orange', cached: 'teal', forwarded: 'blue', local: 'grape', rejected: 'gray' };
const emptyCounts = { total: 0, blocked: 0, cached: 0, forwarded: 0, local: 0, rejected: 0, errors: 0 };

function useVisible() {
  const [visible, setVisible] = useState(!document.hidden);
  useEffect(() => { const change = () => setVisible(!document.hidden); document.addEventListener('visibilitychange', change); return () => document.removeEventListener('visibilitychange', change); }, []);
  return visible;
}

function useWindow(poll: boolean) {
  const [params, setParams] = useSearchParams();
  const hours = params.get('hours') ?? '24';
  const visible = useVisible();
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!poll || !visible) return;
    const timer = setInterval(() => setNow(Date.now()), 10000);
    return () => clearInterval(timer);
  }, [poll, visible]);
  const query = new URLSearchParams();
  const to = params.get('to') ?? String(now);
  query.set('from', params.get('from') ?? String(Number(to) - Number(hours) * 3600000));
  query.set('to', to);
  for (const key of ['client_id', 'domain', 'resolution', 'query_type', 'transport', 'errors']) {
    const value = params.get(key); if (value) query.set(key, value);
  }
  function set(key: string, value: string | null) {
    const next = new URLSearchParams(params);
    if (value) next.set(key, value); else next.delete(key);
    if (key === 'after' && value) {
      next.set('from', query.get('from')!); next.set('to', query.get('to')!);
    } else next.delete('after');
    if (key === 'hours') { next.delete('from'); next.delete('to'); }
    setParams(next);
    if (key !== 'after') setNow(Date.now());
  }
  function refresh() { const next = new URLSearchParams(params); for (const key of ['after', 'from', 'to']) next.delete(key); setParams(next); setNow(Date.now()); }
  return { params, query, hours, set, refresh, visible };
}

function WindowControls({ window: w, refresh }: { window: ReturnType<typeof useWindow>; refresh(): void }) {
  return <Group align="end" justify="space-between"><Group align="end">
    <Select label="Time range" value={w.hours} data={[{ value: '1', label: 'Last hour' }, { value: '24', label: 'Last 24 hours' }, { value: '168', label: 'Last 7 days' }]} onChange={value => w.set('hours', value)} w={180} />
    {w.params.get('client_id') ? <Button variant="light" onClick={() => w.set('client_id', null)}>Client #{w.params.get('client_id')} ×</Button> : null}
    {w.params.get('from') ? <Text size="sm">Selected interval: {date(Number(w.params.get('from')))} – {date(Number(w.params.get('to')))}</Text> : null}
  </Group><Button variant="default" onClick={refresh}>Refresh</Button></Group>;
}

function useMetric<T>(path: string, query: URLSearchParams) {
  const api = useApi();
  const url = `${path}?${query}`;
  const result = useQuery({ queryKey: [url], queryFn: ({ signal }) => api.read<Envelope<T>>(url, signal), placeholderData: previous => previous });
  const previous = useRef(result.data);
  useEffect(() => {
    if (result.data && !result.isPlaceholderData) previous.current = result.data;
  }, [result.data, result.isPlaceholderData]);
  // Each rolling window has a new query key; placeholderData disappears on error.
  return { ...result, data: result.data ?? (result.isError ? previous.current : undefined) };
}

function HealthNotice() {
  const api = useApi();
  const visible = useVisible();
  const health = useQuery({ queryKey: ['/metrics/health'], queryFn: ({ signal }) => api.read<Health>('/metrics/health', signal), refetchInterval: visible ? 10000 : false });
  return <>
    <ErrorNotice error={health.error} />
    {health.data && (!health.data.data.writer_healthy || health.data.data.dropped_events_since_start > 0) ? <Alert color="orange" title="Request history is incomplete">
      {health.data.data.writer_healthy ? 'The history writer is available.' : 'The history writer could not persist its last batch.'} {number.format(health.data.data.dropped_events_since_start)} events dropped since startup. DNS continues serving. Pending events: {health.data.data.pending_events}.
    </Alert> : null}
  </>;
}

function VolumeChart({ response, query }: { response: Envelope<Bucket[]>; query: URLSearchParams }) {
  const rows: Bucket[] = [];
  const byTime = new Map(response.data.map(row => [row.start_ms, row]));
  for (let time = response.from_ms; time < response.to_ms; time += response.interval_ms) rows.push(byTime.get(time) ?? { ...emptyCounts, start_ms: time });
  const max = Math.max(1, ...rows.map(row => row.total));
  const scale = Math.max(4, Math.ceil(max / 4) * 4);
  return <section className="activity-panel" aria-labelledby="volume-heading">
    <Group justify="space-between" mb="sm"><Title id="volume-heading" order={2} size="h3">Request activity</Title><Text size="xs" c="dimmed">Requests per {response.interval_ms / 60000} minutes</Text></Group>
    <div className="chart-layout">
      <div className="chart-scale" aria-hidden="true">{[4, 3, 2, 1, 0].map(step => <span key={step}>{number.format(scale * step / 4)}</span>)}</div>
      <div className="metrics-chart" aria-label="Recorded requests over time">
        <div className="chart-grid" aria-hidden="true">{[0, 1, 2, 3, 4].map(step => <span key={step} />)}</div>
        {rows.map(row => {
          const target = new URLSearchParams(query); target.set('from', String(row.start_ms)); target.set('to', String(Math.min(row.start_ms + response.interval_ms, response.to_ms)));
          const label = `${date(row.start_ms)}: ${number.format(row.total)} requests, ${outcomes.map(outcome => `${number.format(row[outcome])} ${outcome}`).join(', ')}`;
          return <Tooltip key={row.start_ms} events={{ hover: true, focus: true, touch: true }} multiline w={230} withArrow label={<div><Text size="xs" fw={600}>{date(row.start_ms)}</Text><Text size="xs">{number.format(row.total)} requests</Text>{outcomes.map(outcome => <Text size="xs" key={outcome}>{outcome}: {number.format(row[outcome])}</Text>)}</div>}>
            <Link to={`/requests?${target}`} className="metrics-bar" aria-label={label}>
              {outcomes.map(outcome => <span key={outcome} className={`metric-${outcome}`} style={{ height: `${100 * row[outcome] / scale}%` }} />)}
            </Link>
          </Tooltip>;
        })}
      </div>
      <div className="chart-times" aria-hidden="true">{[0, 1, 2, 3, 4].map(step => <span key={step}>{new Date(response.from_ms + (response.to_ms - response.from_ms) * step / 4).toLocaleString(undefined, response.to_ms - response.from_ms > 86400000 ? { month: 'short', day: 'numeric', hour: 'numeric' } : { hour: '2-digit', minute: '2-digit' })}</span>)}</div>
    </div>
    <Group gap="md" mt="md">{outcomes.map(outcome => <Text key={outcome} size="xs" tt="capitalize"><span className={`legend-dot metric-${outcome}`} />{outcome}</Text>)}</Group>
    <Text size="xs" c="dimmed" mt="xs">Select a bar to inspect requests. Errors can overlap any outcome.</Text>
    <details><summary>View chart data as a table</summary><Table.ScrollContainer minWidth={600}><Table><Table.Thead><Table.Tr><Table.Th>Time</Table.Th>{outcomes.map(outcome => <Table.Th key={outcome}>{outcome}</Table.Th>)}</Table.Tr></Table.Thead><Table.Tbody>{rows.map(row => <Table.Tr key={row.start_ms}><Table.Td>{date(row.start_ms)}</Table.Td>{outcomes.map(outcome => <Table.Td key={outcome}>{number.format(row[outcome])}</Table.Td>)}</Table.Tr>)}</Table.Tbody></Table></Table.ScrollContainer></details>
  </section>;
}

export function MetricsOverview({ runtime }: { runtime?: {
  listener: ReactNode; notices: ReactNode; refresh(): Promise<unknown>; fetching: boolean;
} }) {
  const w = useWindow(true);
  const queryClient = useQueryClient();
  const healthFetching = useIsFetching({ queryKey: ['/metrics/health'] }) > 0;
  const summary = useMetric<Summary>('/metrics/summary', w.query);
  const series = useMetric<Bucket[]>('/metrics/timeseries', w.query);
  const rankedQuery = new URLSearchParams(w.query); rankedQuery.set('limit', '5');
  const clients = useMetric<Client[]>('/metrics/clients', rankedQuery);
  const queriedDomains = useMetric<(Counts & { domain: string })[]>('/metrics/domains', rankedQuery);
  const domainsQuery = new URLSearchParams(rankedQuery); domainsQuery.set('resolution', 'blocked');
  const domains = useMetric<(Counts & { domain: string })[]>('/metrics/domains', domainsQuery);
  const memberships = useMemberships([...(queriedDomains.data?.data.data.map(row => row.domain) ?? []), ...(domains.data?.data.data.map(row => row.domain) ?? [])]);
  const queries = [summary, series, clients, queriedDomains, domains];
  const fetching = runtime?.fetching || healthFetching || queries.some(query => query.isFetching);
  const error = queries.find(query => query.error)?.error;
  const s = summary.data?.data.data;
  function history(filters: Record<string, string> = {}) {
    const target = new URLSearchParams(w.query);
    for (const [key, value] of Object.entries(filters)) target.set(key, value);
    return `/requests?${target}`;
  }
  const observed = queries.flatMap(query => query.data ? [query.data.data.observed_at_ms] : []);
  const stale = queries.some(query => query.isError && query.data || query.isPlaceholderData);
  function domainTable(title: string, response: typeof domains, blocked: boolean) {
    return <section className="ranking-section"><Title order={2} size="h3" mb="sm">{title}</Title>
      {response.isPending ? <Skeleton height={180} /> : response.data ? <>
        <Table className="metrics-data"><Table.Thead><Table.Tr><Table.Th>Domain</Table.Th><Table.Th className="membership-column">Lists now</Table.Th><Table.Th ta="right">{blocked ? 'Blocked' : 'Requests'}</Table.Th></Table.Tr></Table.Thead>
          <Table.Tbody>{response.data.data.data.map(row => <Table.Tr key={row.domain}>
            <Table.Td><div className="domain-membership"><DomainLink domain={row.domain} window={w.query} /><div className="membership-inline"><Memberships domain={row.domain} result={memberships} window={w.query} /></div></div></Table.Td>
            <Table.Td className="membership-column"><Memberships domain={row.domain} result={memberships} window={w.query} /></Table.Td>
            <Table.Td ta="right">{number.format(row.total)}</Table.Td>
          </Table.Tr>)}</Table.Tbody></Table>
        {response.data.data.data.length === 0 ? <Text size="sm" c="dimmed" my="md">No {blocked ? 'blocked ' : ''}requests in this period.</Text> : null}
      </> : <Text size="sm" c="dimmed">Domain statistics unavailable.</Text>}
      <Link className="ranking-more" to={history(blocked ? { resolution: 'blocked' } : {})}>View {blocked ? 'blocked ' : ''}requests →</Link>
    </section>;
  }
  return <Stack gap="lg">
    {runtime ? <div className="overview-toolbar"><div><Title order={1}>Overview</Title><div className="overview-listener">{runtime.listener}</div></div>
      <Stack gap={6} align="end"><Group align="end" gap="sm"><Select aria-label="Time range" value={w.hours} data={[{ value: '1', label: 'Last hour' }, { value: '24', label: 'Last 24 hours' }, { value: '168', label: 'Last 7 days' }]} onChange={value => w.set('hours', value)} w={170} />
        <Button variant="default" loading={fetching} onClick={() => { w.refresh(); void runtime.refresh(); void queryClient.refetchQueries({ queryKey: ['/metrics/health'] }); }}>Refresh</Button></Group>
        <Text size="xs" c={stale ? 'orange' : 'dimmed'} role="status">{stale ? 'Previous data · ' : ''}{fetching ? 'Updating…' : observed.length ? `Updated ${new Date(Math.min(...observed)).toLocaleTimeString()}` : 'Waiting for activity'} · Auto-refresh 10s</Text>
      </Stack>
    </div> : <><Title order={2}>Client DNS activity</Title><WindowControls window={w} refresh={w.refresh} /></>}
    {runtime?.notices}<HealthNotice /><ErrorNotice error={error} />
    {runtime && (w.params.get('client_id') || w.params.get('from')) ? <Group><Text size="sm">Filtered view{w.params.get('client_id') ? ` · Client #${w.params.get('client_id')}` : ''}{w.params.get('from') ? ` · ${date(Number(w.params.get('from')))} – ${date(Number(w.params.get('to')))}` : ''}</Text><Button size="xs" variant="subtle" component={Link} to={`/?hours=${w.hours}`}>Reset filters</Button></Group> : null}
    {s ? <dl className="metrics-summary">
      <div><dt>Requests</dt><dd><Link to={history()}>{number.format(s.total)}</Link><Text size="xs" c="dimmed">Recorded in this period</Text></dd></div>
      <div><dt>Blocked</dt><dd><Link to={history({ resolution: 'blocked' })}>{number.format(s.blocked)}</Link> <small>{percent(s.blocked_percentage)}</small><Text size="xs" c="dimmed">Of all recorded requests</Text></dd></div>
      <div><dt>Cache hit rate</dt><dd><Tooltip label="Cached ÷ (cached + forwarded)" events={{ hover: true, focus: true, touch: true }}><Link to={history({ resolution: 'cached' })}>{percent(s.cache_hit_percentage)}</Link></Tooltip><Text size="xs" c="dimmed">Cached ÷ (cached + forwarded)</Text></dd></div>
      <div><dt>Active clients</dt><dd><Link to={`/clients?${w.query}`}>{number.format(s.active_clients)}</Link><Text size="xs" c="dimmed">With matching requests</Text></dd></div>
      <div><dt>Errors</dt><dd><Link to={history({ errors: 'true' })}>{number.format(s.errors)}</Link><Text size="xs" c="dimmed">May overlap any outcome</Text></dd></div>
    </dl> : summary.isPending ? <Skeleton height={110} /> : null}
    {series.data ? <VolumeChart response={series.data.data} query={w.query} /> : series.isPending ? <Skeleton height={300} /> : <Text c="dimmed">Request activity unavailable.</Text>}
    {s?.total === 0 ? <Text c="dimmed">No recorded requests in this period. Send a DNS query to this server to begin collecting history.</Text> : null}
    <div className="metrics-tables">
      <section className="ranking-section"><Title order={2} size="h3" mb="sm">Top clients</Title>
        {clients.isPending ? <Skeleton height={180} /> : clients.data ? <>
          <Table className="metrics-data"><Table.Thead><Table.Tr><Table.Th>Client</Table.Th><Table.Th ta="right">Requests</Table.Th><Table.Th ta="right">Blocked</Table.Th></Table.Tr></Table.Thead><Table.Tbody>
            {clients.data.data.data.slice(0, 5).map(client => <Table.Tr key={client.id}><Table.Td><Link to={history({ client_id: String(client.id) })}>{client.name || client.ip_address}</Link>{client.name ? <Text size="xs" c="dimmed">{client.ip_address}</Text> : null}</Table.Td><Table.Td ta="right">{number.format(client.total)}</Table.Td><Table.Td ta="right">{percent(client.total ? 100 * client.blocked / client.total : 0)}</Table.Td></Table.Tr>)}
          </Table.Tbody></Table>
          {clients.data.data.data.length === 0 ? <Text size="sm" c="dimmed" my="md">No active clients in this period.</Text> : null}
        </> : <Text size="sm" c="dimmed">Client statistics unavailable.</Text>}
        <Link className="ranking-more" to={`/clients?${w.query}`}>View clients →</Link>
      </section>
      {domainTable('Top queried domains', queriedDomains, false)}
      {domainTable('Top blocked domains', domains, true)}
    </div>
    <Text size="xs" c="dimmed">Recorded history · Seven-day retention · Counts exclude unrecorded or dropped events.</Text>
  </Stack>;
}

function ClientName({ client }: { client: Client }) {
  const api = useApi();
  const cache = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(client.name ?? '');
  const [error, setError] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState('');
  const [serverName, setServerName] = useState(client.name);
  async function reloadRevision() {
    setError(null); setBusy(true);
    try {
      const [status, identity] = await Promise.all([api.read<Schema<'Status'>>('/status'), api.read<Schema<'ClientIdentity'>>(`/clients/${client.id}`)]);
      setRevision(status.etag); setServerName(identity.data.name);
    } catch (cause) { setError(cause); } finally { setBusy(false); }
  }
  async function edit() {
    setError(null); setBusy(true);
    try { const status = await api.read<Schema<'Status'>>('/status'); setRevision(status.etag); setName(client.name ?? ''); setEditing(true); }
    catch (cause) { setError(cause); } finally { setBusy(false); }
  }
  async function save() {
    setBusy(true); setError(null);
    try { await api.request(`/clients/${client.id}`, 'PATCH', { name: name || null }, revision); setEditing(false); await cache.invalidateQueries(); }
    catch (cause) { setError(cause); } finally { setBusy(false); }
  }
  return <Stack gap="xs"><ErrorNotice error={error} />{editing ? <><Group align="end"><TextInput label="Client name" description="Leave empty to clear the name." value={name} maxLength={256} onChange={event => setName(event.currentTarget.value)} /><Button loading={busy} onClick={() => void save()}>Save</Button><Button variant="subtle" disabled={busy} onClick={() => setEditing(false)}>Cancel</Button><Button variant="subtle" disabled={busy} onClick={() => void reloadRevision()}>Reload revision, keep draft</Button></Group><Text size="xs">Last reviewed server name: {serverName ?? 'Unnamed client'}. Saving replaces this name.</Text></> : <Group><Text>{client.name ?? 'Unnamed client'}</Text><Button size="xs" variant="subtle" loading={busy} onClick={() => void edit()}>Edit name</Button></Group>}</Stack>;
}

export function ClientsPage() {
  const w = useWindow(false);
  const [search, setSearch] = useState('');
  const query = new URLSearchParams(w.query);
  if (w.params.get('after')) query.set('after', w.params.get('after')!);
  const clients = useMetric<Client[]>('/clients', query);
  const selected = w.params.get('client_id');
  return <Stack gap="lg"><Title order={1}>{selected ? 'Client details' : 'Clients'}</Title><WindowControls window={w} refresh={() => { w.refresh(); void clients.refetch(); }} /><HealthNotice /><ErrorNotice error={clients.error} />
    <Text size="sm" c="dimmed">Counts cover the selected period. IP addresses identify observed requesters; a shared DNS proxy appears as one client.</Text>
    <TextInput label="Filter this page by name or IP" value={search} onChange={event => setSearch(event.currentTarget.value)} />
    {clients.isPending ? <Skeleton height={180} /> : null}
    <Table.ScrollContainer minWidth={900}><Table className="metrics-data"><Table.Thead><Table.Tr>{['Client', 'IP address', 'Requests', 'Blocked', 'Cached', 'Forwarded', 'Local', 'Rejected', 'Errors', 'Last seen'].map(label => <Table.Th key={label}>{label}</Table.Th>)}</Table.Tr></Table.Thead><Table.Tbody>
      {clients.data?.data.data.filter(c => `${c.name ?? ''} ${c.ip_address}`.toLowerCase().includes(search.toLowerCase())).map(client => <Table.Tr key={client.id}><Table.Td>{selected ? <ClientName client={client} /> : <Link to={`/clients?client_id=${client.id}&hours=${w.hours}`}>{client.name ?? client.ip_address}</Link>}</Table.Td><Table.Td>{client.ip_address}</Table.Td>{[client.total, client.blocked, client.cached, client.forwarded, client.local, client.rejected, client.errors].map((value, i) => <Table.Td key={i}>{number.format(value)}</Table.Td>)}<Table.Td>{date(client.last_seen_at_ms)}</Table.Td></Table.Tr>)}
    </Table.Tbody></Table></Table.ScrollContainer>
    {clients.data?.data.data.length === 0 ? <Text>No clients recorded yet.</Text> : null}
    {clients.data?.data.next ? <Button variant="default" onClick={() => w.set('after', clients.data!.data.next)}>Next page</Button> : null}
    {selected ? <><MetricsOverview /><Link to={`/requests?client_id=${selected}&hours=${w.hours}`}>View client request history</Link></> : null}
  </Stack>;
}

export function RequestsPage() {
  const w = useWindow(false);
  const query = new URLSearchParams(w.query);
  if (w.params.get('after')) query.set('after', w.params.get('after')!);
  const requests = useMetric<Request[]>('/requests', query);
  const [expanded, setExpanded] = useState<number | null>(null);
  const [domain, setDomain] = useState(w.params.get('domain') ?? '');
  const memberships = useMemberships(requests.data?.data.data.map(row => row.domain) ?? []);
  const domainFilter = w.params.get('domain') ?? '';
  useEffect(() => { setDomain(domainFilter); }, [domainFilter]);
  return <Stack gap="lg"><Title order={1}>Request history</Title><WindowControls window={w} refresh={w.refresh} /><HealthNotice />
    <Group align="end"><Select label="Outcome" clearable value={w.params.get('resolution')} data={outcomes.map(value => ({ value, label: value }))} onChange={value => w.set('resolution', value)} />
      <form onSubmit={event => { event.preventDefault(); w.set('domain', domain || null); }}><Group align="end"><TextInput label="Exact domain" value={domain} onChange={event => setDomain(event.currentTarget.value)} /><Button type="submit" variant="default">Filter</Button></Group></form>
      <TextInput label="Client ID" value={w.params.get('client_id') ?? ''} onChange={event => w.set('client_id', event.currentTarget.value || null)} w={110} />
      <Select label="Query type" clearable value={w.params.get('query_type')} data={[{ value: '1', label: 'A' }, { value: '28', label: 'AAAA' }, { value: '5', label: 'CNAME' }, { value: '15', label: 'MX' }, { value: '16', label: 'TXT' }, { value: '65', label: 'HTTPS' }]} onChange={value => w.set('query_type', value)} />
      <Select label="Transport" clearable value={w.params.get('transport')} data={['udp', 'tcp']} onChange={value => w.set('transport', value)} />
      <Checkbox label="Errors only" checked={w.params.get('errors') === 'true'} onChange={event => w.set('errors', event.currentTarget.checked ? 'true' : null)} mb={8} />
    </Group><ErrorNotice error={requests.error} />
    <Text size="sm" c="dimmed">History stays still while you inspect it. Refresh to see new requests. All times use your browser’s timezone.</Text>
    <Text size="xs" c="dimmed">List pills show current active memberships, not which source caused a recorded outcome.</Text>
    {requests.isPending ? <Skeleton height={200} /> : null}
    <Table.ScrollContainer minWidth={850}><Table className="metrics-data">
      <Table.Thead><Table.Tr>{['Time', 'Client', 'Domain', 'Lists now', 'Type', 'Outcome', 'Duration', 'Details'].map(label => <Table.Th key={label} className={label === 'Lists now' ? 'membership-column' : undefined}>{label}</Table.Th>)}</Table.Tr></Table.Thead>
      <Table.Tbody>{requests.data?.data.data.map(row => <Table.Tr key={row.id}>
        <Table.Td>{date(row.received_at_ms)}</Table.Td>
        <Table.Td><Link to={`/clients?client_id=${row.client_id}`}>{row.client_name ?? row.ip_address}</Link></Table.Td>
        <Table.Td>{row.domain ? <div className="domain-membership"><DomainLink domain={row.domain} type={row.query_type} outcome={row.resolution} window={w.query} /><div className="membership-inline"><Memberships domain={row.domain} result={memberships} window={w.query} /></div></div> : 'Unavailable'}{expanded === row.id ? <Text size="xs" mt="xs">{row.transport.toUpperCase()} · Class {row.query_class ?? 'unknown'} · RCODE {row.rcode ?? 'none'} · {row.error ?? 'No processing error'}</Text> : null}</Table.Td>
        <Table.Td className="membership-column">{row.domain ? <Memberships domain={row.domain} result={memberships} window={w.query} /> : 'Unavailable'}</Table.Td>
        <Table.Td>{row.query_type === 1 ? 'A' : row.query_type === 28 ? 'AAAA' : row.query_type ?? 'Unknown'}</Table.Td>
        <Table.Td><Badge color={colors[row.resolution]} variant="light">{row.resolution}</Badge>{row.error ? <Text size="xs" c="red">Error</Text> : null}</Table.Td>
        <Table.Td>{(row.duration_us / 1000).toFixed(2)} ms</Table.Td>
        <Table.Td><Button size="xs" variant="subtle" aria-expanded={expanded === row.id} onClick={() => setExpanded(expanded === row.id ? null : row.id)}>{expanded === row.id ? 'Hide' : 'Show'}</Button></Table.Td>
      </Table.Tr>)}</Table.Tbody>
    </Table></Table.ScrollContainer>
    {requests.data?.data.data.length === 0 ? <Text>No recorded requests match these filters.</Text> : null}
    {requests.data?.data.next ? <Button variant="default" onClick={() => w.set('after', requests.data!.data.next)}>Older requests</Button> : null}
  </Stack>;
}
