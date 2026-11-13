import { useMemo } from 'react';
import { Alert, Badge, Button, Divider, Drawer, Group, Select, Skeleton, Stack, Table, Text, Title } from '@mantine/core';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useLocation, useSearchParams } from 'react-router-dom';
import { ApiError, useApi, type Schema } from './api';
import { ErrorNotice } from './components';

type MembershipSource = Schema<'MembershipSource'>;
type MembershipMatches = Schema<'MembershipMatches'>;
type MembershipResult = { isError: boolean; isPending: boolean; matches: Map<string, MembershipSource[]> };
const normalize = (name: string) => name.trim().toLowerCase().replace(/\.$/, '');

export function useMemberships(names: (string | null | undefined)[]) {
  const api = useApi();
  const domains = [...new Set(names.filter((name): name is string => Boolean(name)).map(normalize))].sort();
  const key = JSON.stringify(domains);
  const query = useQuery({ queryKey: ['/blocklists/matches', key], enabled: domains.length > 0, queryFn: () => api.request<MembershipMatches>('/blocklists/matches', 'POST', { domains }), refetchInterval: domains.length ? 30000 : false });
  const matches = useMemo(() => {
    const sources = new Map(query.data?.data.sources.map(source => [source.id, source]));
    return new Map(query.data?.data.matches.map(match => [match.domain, match.source_ids.flatMap(id => { const source = sources.get(id); return source ? [source] : []; })]));
  }, [query.data]);
  return { ...query, matches };
}

export function SourcePills({ domain, sources, window }: { domain: string; sources: MembershipSource[]; window?: URLSearchParams }) {
  const location = useLocation();
  function pill(source: MembershipSource) {
    const label = source.name ? `${source.name} (${source.id})` : source.id;
    const target = new URLSearchParams({ domain, snapshot: 'active' });
    const context = window ?? new URLSearchParams(location.search);
    for (const key of ['from', 'to', 'hours']) { const value = context.get(key); if (value) target.set(key, value); }
    return <Link key={source.id} className="membership-pill" to={`/blocklists/${encodeURIComponent(source.id)}?${target}`} aria-label={`View ${domain} in ${label}${source.status.state === 'degraded' ? ', degraded, serving saved data' : ''}`}>{label}{source.status.state === 'degraded' ? ' · degraded' : ''}</Link>;
  }
  return <div className="membership-pills" aria-label="Current imported list memberships">{sources.slice(0, 2).map(pill)}{sources.length > 2 ? <details className="membership-more"><summary aria-label={`Show ${sources.length - 2} more current list memberships`}>+{sources.length - 2}</summary><div className="membership-overflow">{sources.slice(2).map(pill)}</div></details> : null}</div>;
}

export function Memberships({ domain, result, window }: { domain: string; result: MembershipResult; window?: URLSearchParams }) {
  if (result.isError) return <Text size="xs" c="orange" role="status">Current list membership unavailable</Text>;
  if (result.isPending) return <Text size="xs" c="dimmed">Loading current list memberships…</Text>;
  const sources = result.matches.get(normalize(domain));
  if (!sources) return <Text size="xs" c="orange">Current list membership unavailable</Text>;
  return sources.length ? <SourcePills domain={normalize(domain)} sources={sources} window={window} /> : <Text size="xs" c="dimmed">No active list match</Text>;
}

export function DomainLink({ domain, type = 1, outcome, window }: { domain: string; type?: number | null; outcome?: string; window?: URLSearchParams }) {
  const location = useLocation();
  const params = new URLSearchParams(location.search);
  params.set('inspect', domain); params.set('inspect_type', String(type ?? 1));
  if (outcome) params.set('recorded_outcome', outcome); else params.delete('recorded_outcome');
  if (window) for (const key of ['from', 'to']) { const value = window.get(key); if (value) params.set(key, value); }
  return <Link to={`${location.pathname}?${params}`} aria-label={`Inspect ${domain}`}>{domain}</Link>;
}

export function requestsForDomain(domain: string, current: URLSearchParams) {
  const params = new URLSearchParams();
  for (const key of ['from', 'to', 'hours']) { const value = current.get(key); if (value) params.set(key, value); }
  params.set('domain', domain);
  return `/requests?${params}`;
}

const reasonLabels: Record<Schema<'Policy'>['reason'], string> = {
  explicit_block: 'Explicit block takes precedence.', explicit_allow: 'Explicit allow bypasses imported blocklists.', local_record: 'A matching local record answers this type.', imported_blocklist: 'Imported blocklist membership blocks this exact name.', default_forward: 'Normal cache or upstream handling applies.',
};

export function CurrentPolicyResult({ result, revision }: { result: Schema<'Policy'>; revision: string }) {
  const api = useApi();
  const records = useQuery({ queryKey: ['/records', 'inspect', result.name], queryFn: ({ signal }) => Promise.all(['A', 'AAAA'].map(async type => {
    try { return (await api.read<Schema<'Record'>>(`/records/${encodeURIComponent(`${type}:${result.name}`)}`, signal)).data; }
    catch (error) { if (error instanceof ApiError && error.status === 404 && error.code !== 'ApiNotFound') return null; throw error; }
  })) });
  return <Stack gap="sm">
    <Group justify="space-between"><Title order={3} size="h4">Current policy</Title><Badge variant="light" color={result.decision === 'block' ? 'orange' : 'teal'}>{result.decision === 'local' ? 'Local answer' : result.decision === 'block' ? 'Block' : 'Forward policy'}</Badge></Group>
    <Text size="sm">{reasonLabels[result.reason]}</Text><Text size="xs" c="dimmed">Type {result.type} · class IN · revision {revision} · membership generation {result.membership_generation}</Text>
    <Table><Table.Tbody>{[['Explicit block', result.explicit_block], ['Explicit allow', result.explicit_allow], ['Imported blocklist', result.imported_block], ['Local record for this type', result.local_record]].map(([label, match]) => <Table.Tr key={String(label)}><Table.Th>{label}</Table.Th><Table.Td>{match ? 'Match' : 'No match'}</Table.Td></Table.Tr>)}</Table.Tbody></Table>
    <Text size="sm" fw={600}>Current list memberships</Text>
    {result.matching_sources.length ? <SourcePills domain={result.name} sources={result.matching_sources} /> : <Text size="sm" c="dimmed">No active list match</Text>}
    <Text size="xs" c="dimmed">Active memberships now, including degraded sources serving saved data. These do not attribute any recorded request outcome.</Text>
    <Divider /><Title order={3} size="h4">Matching local records</Title>
    {records.isPending ? <Skeleton height={50} /> : records.isError ? <ErrorNotice error={records.error} /> : <>{records.data?.filter(record => record !== null).map(record => <div key={record.id}><Text size="sm" fw={600}>{record.type} · TTL {record.ttl}s</Text><Text size="sm">{record.addresses.join(', ')}</Text><Text size="xs" c="dimmed">{(result.type === 1 && record.type === 'A') || (result.type === 28 && record.type === 'AAAA') ? 'Matches selected question type' : 'Does not match selected question type'}</Text></div>)}{records.data?.every(record => record === null) ? <Text size="sm" c="dimmed">No matching A or AAAA record sets.</Text> : null}</>}
    <Alert color="gray" title="Policy only, no DNS lookup">No upstream query is performed. Forward policy may use a cached answer. Explicit blocks take precedence over allows and local records.</Alert>
  </Stack>;
}

export function DomainInspection() {
  const [params, setParams] = useSearchParams();
  const client = useQueryClient();
  const name = params.get('inspect');
  const rawType = params.get('inspect_type') ?? '1';
  const validType = /^\d+$/.test(rawType) && Number(rawType) <= 65535;
  const api = useApi();
  const path = `/policy/check?${new URLSearchParams({ name: name ?? '', type: rawType })}`;
  const policy = useQuery({ queryKey: [path], queryFn: ({ signal }) => api.read<Schema<'Policy'>>(path, signal), enabled: Boolean(name) && validType });
  function close() { const next = new URLSearchParams(params); for (const key of ['inspect', 'inspect_type', 'recorded_outcome']) next.delete(key); setParams(next); }
  const outcome = params.get('recorded_outcome');
  return <Drawer opened={Boolean(name)} onClose={close} position="right" size="lg" classNames={{ content: 'domain-inspection' }} title="Domain inspection" closeButtonProps={{ 'aria-label': 'Close domain inspection' }}>
    {name ? <Stack gap="lg"><Text fw={600} style={{ overflowWrap: 'anywhere' }}>{name}</Text>
      {outcome ? <section><Title order={3} size="h4" mb="xs">Recorded outcome</Title><Badge color="gray" variant="light">{outcome}</Badge><Text size="sm" c="dimmed" mt="xs">What happened for the selected request, not a statement of current policy. Historical source attribution is not recorded.</Text></section> : null}
      <Select label="Inspect question type" value={rawType} allowDeselect={false} data={[{ value: '1', label: 'A · IPv4' }, { value: '28', label: 'AAAA · IPv6' }, ...(!['1', '28'].includes(rawType) ? [{ value: rawType, label: `DNS type ${rawType}` }] : [])]} onChange={value => { if (value) { const next = new URLSearchParams(params); next.set('inspect_type', value); setParams(next); } }} />
      {!validType ? <Alert color="red">Question type must be an integer from 0 to 65535.</Alert> : null}
      <ErrorNotice error={policy.error} />{policy.isPending && validType ? <Skeleton height={220} /> : !policy.isError && policy.data ? <CurrentPolicyResult result={policy.data.data} revision={policy.data.etag} /> : null}
      <Group><Button variant="default" component={Link} to={requestsForDomain(name, params)}>View requests</Button><Button variant="light" component={Link} to={`/domains?${new URLSearchParams({ domain: name, create: 'allow' })}`}>Add allow rule</Button><Button variant="subtle" loading={policy.isFetching} onClick={() => { void policy.refetch(); void client.invalidateQueries({ queryKey: ['/records', 'inspect'] }); }} disabled={!validType}>Refresh policy</Button></Group>
    </Stack> : null}
  </Drawer>;
}
