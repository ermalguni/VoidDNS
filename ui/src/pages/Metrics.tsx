import { useEffect, useState } from 'react';
import { Alert, Badge, Button, Checkbox, Group, Select, Skeleton, Stack, Table, Text, TextInput, Title } from '@mantine/core';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useSearchParams } from 'react-router-dom';
import { useApi, type Schema } from '../api';
import { ErrorNotice } from '../components';

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
  return useQuery({ queryKey: [url], queryFn: ({ signal }) => api.read<Envelope<T>>(url, signal), placeholderData: previous => previous });
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
  return <section aria-labelledby="volume-heading"><Title id="volume-heading" order={3}>Request volume</Title>
    <Group gap="md" my="sm">{outcomes.map(outcome => <Badge key={outcome} color={colors[outcome]} variant="light">{outcome}</Badge>)}</Group>
    <Text size="xs" c="dimmed">Requests per {response.interval_ms / 60000} minutes · vertical scale 0–{number.format(max)} · select a bar to inspect requests</Text>
    <div className="metrics-chart" aria-label="Recorded requests over time">
      {rows.map(row => {
        const target = new URLSearchParams(query); target.set('from', String(row.start_ms)); target.set('to', String(Math.min(row.start_ms + response.interval_ms, response.to_ms)));
        const label = `${date(row.start_ms)}: ${row.total} requests, ${outcomes.map(outcome => `${row[outcome]} ${outcome}`).join(', ')}`;
        return <Link key={row.start_ms} to={`/requests?${target}`} className="metrics-bar" title={label} aria-label={label}>
          {outcomes.map(outcome => <span key={outcome} className={`metric-${outcome}`} style={{ height: `${100 * row[outcome] / max}%` }} />)}
        </Link>;
      })}
    </div>
    <Group justify="space-between"><Text size="xs">{date(response.from_ms)}</Text><Text size="xs">{date(response.to_ms)}</Text></Group>
    <details><summary>View chart data as a table</summary><Table.ScrollContainer minWidth={600}><Table><Table.Thead><Table.Tr><Table.Th>Time</Table.Th>{outcomes.map(outcome => <Table.Th key={outcome}>{outcome}</Table.Th>)}</Table.Tr></Table.Thead><Table.Tbody>{rows.map(row => <Table.Tr key={row.start_ms}><Table.Td>{date(row.start_ms)}</Table.Td>{outcomes.map(outcome => <Table.Td key={outcome}>{number.format(row[outcome])}</Table.Td>)}</Table.Tr>)}</Table.Tbody></Table></Table.ScrollContainer></details>
  </section>;
}

export function MetricsOverview() {
  const w = useWindow(true);
  const summary = useMetric<Summary>('/metrics/summary', w.query);
  const series = useMetric<Bucket[]>('/metrics/timeseries', w.query);
  const clients = useMetric<Client[]>('/metrics/clients', w.query);
  const domainsQuery = new URLSearchParams(w.query); domainsQuery.set('resolution', 'blocked'); domainsQuery.set('limit', '10');
  const domains = useMetric<(Counts & { domain: string })[]>('/metrics/domains', domainsQuery);
  const error = summary.error || series.error || clients.error || domains.error;
  const s = summary.data?.data.data;
  return <Stack gap="lg">
    <Group justify="space-between"><Title order={2}>DNS activity</Title><Text size="sm" c="dimmed">Recorded history · 7-day retention</Text></Group>
    <WindowControls window={w} refresh={w.refresh} />
    <HealthNotice /><ErrorNotice error={error} />
    {error && summary.data ? <Text c="orange" role="status">Showing previous data. Last observed: {date(summary.data.data.observed_at_ms)}.</Text> : null}
    {s ? <dl className="metrics-summary">
      <div><dt>Requests</dt><dd>{number.format(s.total)}</dd></div><div><dt>Blocked</dt><dd>{percent(s.blocked_percentage)}</dd></div>
      <div><dt>Cache hit rate</dt><dd title="Cached ÷ (cached + forwarded)">{percent(s.cache_hit_percentage)}</dd></div>
      <div><dt>Active clients</dt><dd>{s.active_clients}</dd></div><div><dt>Errors</dt><dd>{s.errors}</dd></div>
    </dl> : <Skeleton height={60} />}
    {series.data ? <VolumeChart response={series.data.data} query={w.query} /> : <Skeleton height={220} />}
    {s?.total === 0 ? <Text c="dimmed">No recorded requests in this period. Send a DNS query to this server to begin collecting history.</Text> : null}
    <div className="metrics-tables"><section><Title order={3} mb="sm">Most active clients</Title>
      <Table><Table.Thead><Table.Tr><Table.Th>Client</Table.Th><Table.Th>Requests</Table.Th><Table.Th>Blocked</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{clients.data?.data.data.slice(0, 10).map(client => <Table.Tr key={client.id}><Table.Td><Link to={`/clients?client_id=${client.id}&hours=${w.hours}`}>{client.name ?? client.ip_address}</Link></Table.Td><Table.Td>{number.format(client.total)}</Table.Td><Table.Td>{percent(client.total ? 100 * client.blocked / client.total : 0)}</Table.Td></Table.Tr>)}</Table.Tbody></Table>
    </section><section><Title order={3} mb="sm">Most blocked domains</Title><Table><Table.Thead><Table.Tr><Table.Th>Domain</Table.Th><Table.Th>Requests</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{domains.data?.data.data.map(row => { const target = new URLSearchParams(w.query); target.set('domain', row.domain); target.set('resolution', 'blocked'); return <Table.Tr key={row.domain}><Table.Td><Link to={`/requests?${target}`}>{row.domain}</Link></Table.Td><Table.Td>{number.format(row.total)}</Table.Td></Table.Tr>; })}</Table.Tbody></Table></section></div>
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
  return <Stack gap="lg"><Title order={1}>Request history</Title><WindowControls window={w} refresh={w.refresh} /><HealthNotice />
    <Group align="end"><Select label="Outcome" clearable value={w.params.get('resolution')} data={outcomes.map(value => ({ value, label: value }))} onChange={value => w.set('resolution', value)} />
      <form onSubmit={event => { event.preventDefault(); w.set('domain', domain || null); }}><Group align="end"><TextInput label="Exact domain" value={domain} onChange={event => setDomain(event.currentTarget.value)} /><Button type="submit" variant="default">Filter</Button></Group></form>
      <TextInput label="Client ID" value={w.params.get('client_id') ?? ''} onChange={event => w.set('client_id', event.currentTarget.value || null)} w={110} />
      <Select label="Query type" clearable value={w.params.get('query_type')} data={[{ value: '1', label: 'A' }, { value: '28', label: 'AAAA' }, { value: '5', label: 'CNAME' }, { value: '15', label: 'MX' }, { value: '16', label: 'TXT' }, { value: '65', label: 'HTTPS' }]} onChange={value => w.set('query_type', value)} />
      <Select label="Transport" clearable value={w.params.get('transport')} data={['udp', 'tcp']} onChange={value => w.set('transport', value)} />
      <Checkbox label="Errors only" checked={w.params.get('errors') === 'true'} onChange={event => w.set('errors', event.currentTarget.checked ? 'true' : null)} mb={8} />
    </Group><ErrorNotice error={requests.error} />
    <Text size="sm" c="dimmed">History stays still while you inspect it. Refresh to see new requests. All times use your browser’s timezone.</Text>
    {requests.isPending ? <Skeleton height={200} /> : null}
    <Table.ScrollContainer minWidth={850}><Table className="metrics-data"><Table.Thead><Table.Tr>{['Time', 'Client', 'Domain', 'Type', 'Outcome', 'Duration', 'Details'].map(label => <Table.Th key={label}>{label}</Table.Th>)}</Table.Tr></Table.Thead><Table.Tbody>{requests.data?.data.data.map(row => <Table.Tr key={row.id}><Table.Td>{date(row.received_at_ms)}</Table.Td><Table.Td><Link to={`/clients?client_id=${row.client_id}`}>{row.client_name ?? row.ip_address}</Link></Table.Td><Table.Td>{row.domain ?? 'Unavailable'}{expanded === row.id ? <Text size="xs" mt="xs">{row.transport.toUpperCase()} · Class {row.query_class ?? 'unknown'} · RCODE {row.rcode ?? 'none'} · {row.error ?? 'No processing error'}</Text> : null}</Table.Td><Table.Td>{row.query_type === 1 ? 'A' : row.query_type === 28 ? 'AAAA' : row.query_type ?? 'Unknown'}</Table.Td><Table.Td><Badge color={colors[row.resolution]} variant="light">{row.resolution}</Badge>{row.error ? <Text size="xs" c="red">Error</Text> : null}</Table.Td><Table.Td>{(row.duration_us / 1000).toFixed(2)} ms</Table.Td><Table.Td><Button size="xs" variant="subtle" aria-expanded={expanded === row.id} onClick={() => setExpanded(expanded === row.id ? null : row.id)}>{expanded === row.id ? 'Hide' : 'Show'}</Button></Table.Td></Table.Tr>)}</Table.Tbody></Table></Table.ScrollContainer>
    {requests.data?.data.data.length === 0 ? <Text>No recorded requests match these filters.</Text> : null}
    {requests.data?.data.next ? <Button variant="default" onClick={() => w.set('after', requests.data!.data.next)}>Older requests</Button> : null}
  </Stack>;
}
