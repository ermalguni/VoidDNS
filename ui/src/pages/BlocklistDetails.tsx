import { useEffect, useState } from 'react';
import { Alert, Badge, Button, Group, NumberInput, Select, Skeleton, Stack, Table, Tabs, Text, TextInput } from '@mantine/core';
import { useForm } from '@mantine/form';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { ApiError, useApi, type Schema } from '../api';
import { ErrorNotice, PageHeading } from '../components';
import { DomainLink, requestsForDomain } from '../DomainInspection';
import { ResourceEditor } from './Collections';

export function BlocklistDetailsPage() {
  const { id = '' } = useParams();
  const api = useApi();
  const client = useQueryClient();
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [selection, setSelection] = useState<{ action: 'edit' | 'refresh' | 'delete'; id: string } | null>(null);
  const sourcePath = `/blocklists/${encodeURIComponent(id)}`;
  const source = useQuery({ queryKey: ['/blocklists', sourcePath], queryFn: ({ signal }) => api.read<Schema<'SourceView'>>(sourcePath, signal) });
  const view = source.data?.data;
  const tab = params.get('tab') === 'settings' ? 'settings' : 'domains';
  const requestedSnapshot = params.get('snapshot');
  const snapshot = requestedSnapshot === 'saved' || requestedSnapshot === 'active' ? requestedSnapshot : view?.enabled === false ? 'saved' : 'active';
  const mode = params.has('domain') ? 'domain' : 'prefix';
  const filter = params.get(mode) ?? '';
  const limitValue = Number(params.get('limit') ?? 50);
  const limit = Number.isInteger(limitValue) && limitValue >= 1 && limitValue <= 100 ? limitValue : 50;
  const after = params.get('after');
  const form = useForm({ initialValues: { mode, filter, limit: limit as number | string }, validate: { limit: value => typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 100 ? null : 'Choose an integer from 1 to 100.' } });
  useEffect(() => { form.setValues({ mode, filter, limit }); }, [mode, filter, limit]);
  const query = new URLSearchParams({ snapshot, limit: String(limit) });
  if (filter) query.set(mode, filter);
  if (after) query.set('after', after);
  const path = `${sourcePath}/domains?${query}`;
  const domains = useQuery({ queryKey: ['/blocklists', path], queryFn: ({ signal }) => api.read<Schema<'ListDomainPage'>>(path, signal), enabled: Boolean(view) && tab === 'domains' });
  const unavailable = domains.error instanceof ApiError && domains.error.code === 'SnapshotUnavailable';
  const stale = domains.error instanceof ApiError && domains.error.code === 'StaleCursor';
  function change(values: Record<string, string | null>, resetPage = true) {
    const next = new URLSearchParams(params);
    for (const [key, value] of Object.entries(values)) { if (value) next.set(key, value); else next.delete(key); }
    if (resetPage) { next.delete('after'); next.delete('previous'); }
    setParams(next);
  }
  const page = domains.data?.data;
  return <Stack gap="lg">
    <Link to="/blocklists">← Blocklist sources</Link>
    <PageHeading title={view?.name || id} description={view?.name ? id : undefined} />
    <ErrorNotice error={source.error} />
    {source.isPending ? <Skeleton height={100} /> : source.isError ? <Button variant="default" onClick={() => void source.refetch()}>Retry loading source</Button> : view ? <>
      <Group gap="sm"><Badge color={view.status.state === 'active' ? 'teal' : view.status.state === 'degraded' ? 'yellow' : 'gray'} variant="light">{view.status.state}</Badge><Text size="sm">{view.status.domain_count.toLocaleString()} runtime domains</Text><Text size="sm" c="dimmed">Active snapshot import: {view.status.last_success_at_ms === null ? 'None' : new Date(view.status.last_success_at_ms).toLocaleString()}</Text></Group>
      {view.status.last_error ? <Alert color={view.status.state === 'unavailable' ? 'orange' : 'gray'} title={`Last import error: ${view.status.last_error}`}>{view.status.state === 'degraded' ? 'The active list is using a compatible saved snapshot.' : view.status.state === 'disabled' ? 'This source is disabled and does not contribute current policy.' : 'No compatible snapshot is contributing current policy.'}</Alert> : null}
      <Tabs value={tab} onChange={value => change({ tab: value === 'settings' ? 'settings' : null }, false)}>
        <Tabs.List><Tabs.Tab value="domains">Domains</Tabs.Tab><Tabs.Tab value="settings">Settings</Tabs.Tab></Tabs.List>
        <Tabs.Panel value="domains" pt="lg"><Stack gap="md">
          <Group align="end" justify="space-between"><Select label="Snapshot" value={snapshot} allowDeselect={false} data={[{ value: 'active', label: 'Active · used by DNS now' }, { value: 'saved', label: 'Saved · durable imported data' }]} onChange={value => { if (value) change({ snapshot: value }); }} /><Button variant="default" loading={domains.isFetching || source.isFetching} onClick={() => { void source.refetch(); void domains.refetch(); }}>Reload</Button></Group>
          <Text size="sm" c="dimmed">{snapshot === 'active' ? 'Imported names in the current RAM snapshot. Explicit rules and local records can override list membership.' : 'Imported names stored on disk. Saved data is not necessarily active. A disabled source never contributes blocking policy.'}</Text>
          <form onSubmit={form.onSubmit(values => change({ domain: values.mode === 'domain' ? values.filter.trim() : null, prefix: values.mode === 'prefix' ? values.filter.trim() : null, limit: String(values.limit) }))}><Group align="start">
            <Select label="Search mode" allowDeselect={false} data={[{ value: 'prefix', label: 'Name prefix' }, { value: 'domain', label: 'Exact name' }]} {...form.getInputProps('mode')} />
            <TextInput label={form.values.mode === 'domain' ? 'Exact domain' : 'Domain prefix'} placeholder="All imported names" style={{ flex: '1 1 180px' }} {...form.getInputProps('filter')} />
            <NumberInput label="Rows per page" min={1} max={100} allowDecimal={false} w={140} {...form.getInputProps('limit')} /><Button type="submit" variant="light" mt={25}>Search</Button>{filter ? <Button variant="subtle" mt={25} onClick={() => change({ domain: null, prefix: null })}>Clear search</Button> : null}
          </Group></form>
          {domains.isPending ? <Skeleton height={180} /> : unavailable ? <Alert color="gray" title="Snapshot unavailable">There is no {snapshot} snapshot available for this source. {snapshot === 'active' ? 'Try the saved snapshot or check source settings.' : 'A successful import is required before saved domains can be browsed.'}</Alert> : stale ? <Alert color="orange" title="Snapshot changed"><Stack gap="sm"><Text size="sm">The cursor belongs to an older snapshot. Restart from the first page; the domain filter will be kept.</Text><Button variant="default" onClick={() => { change({ after: null }); void client.invalidateQueries({ queryKey: ['/blocklists'] }); }}>Restart listing</Button></Stack></Alert> : domains.isError ? <><ErrorNotice error={domains.error} /><Button variant="default" onClick={() => void domains.refetch()}>Retry loading domains</Button></> : page ? <>
            <Group gap="sm"><Badge color={page.snapshot.active ? 'teal' : 'gray'} variant="light">{page.snapshot.kind === 'saved' ? 'Saved snapshot' : 'Active snapshot'} · {page.snapshot.active ? 'Currently used by DNS' : 'Not currently used by DNS'}</Badge><Text size="sm">{page.snapshot.domain_count.toLocaleString()} imported domains</Text></Group>
            <Text size="xs" c="dimmed">Snapshot {page.snapshot.version} · Last successful import: {page.snapshot.last_success_at_ms === null ? 'Unknown' : new Date(page.snapshot.last_success_at_ms).toLocaleString()}</Text>
            {page.items.length ? <Table verticalSpacing="sm" withTableBorder><Table.Thead><Table.Tr><Table.Th>Imported domain</Table.Th><Table.Th>Actions</Table.Th></Table.Tr></Table.Thead><Table.Tbody>{page.items.map(domain => <Table.Tr key={domain}><Table.Td><DomainLink domain={domain} /></Table.Td><Table.Td><Group gap="sm"><Link to={requestsForDomain(domain, params)}>View requests</Link><Link to={`/domains?${new URLSearchParams({ domain, create: 'allow' })}`}>Add allow rule</Link></Group></Table.Td></Table.Tr>)}</Table.Tbody></Table> : <Text c="dimmed" py="lg">{filter ? 'No imported names match this search.' : 'This snapshot contains no imported names.'}</Text>}
            <Group justify="space-between"><Text size="sm" c="dimmed">{after ? 'Continued page' : 'First page'} · {page.items.length} names</Text><Group gap="xs"><Button variant="default" disabled={!after || domains.isFetching} onClick={() => { const next = new URLSearchParams(params); const previous = next.getAll('previous'); const cursor = previous.pop(); next.delete('previous'); previous.forEach(value => next.append('previous', value)); if (cursor) next.set('after', cursor); else next.delete('after'); setParams(next); }}>Back</Button><Button variant="default" disabled={!page.next_cursor || domains.isFetching} onClick={() => { if (page.next_cursor) { const next = new URLSearchParams(params); next.append('previous', after ?? ''); next.set('after', page.next_cursor); setParams(next); } }}>Next</Button></Group></Group>
          </> : null}
          <Text size="xs" c="dimmed">Imported domains are read-only. Change the upstream source or add an explicit allow rule; individual imported names cannot be deleted here.</Text>
        </Stack></Tabs.Panel>
        <Tabs.Panel value="settings" pt="lg"><Stack>
          <Table><Table.Tbody>{[['Source ID', view.id], ['Enabled', view.enabled ? 'Yes' : 'No'], ['Location', view.source.value], ['Kind', view.source.kind], ['Format', view.format], ['Provenance', view.api_managed ? 'API-managed' : 'Operator-provided']].map(([label, value]) => <Table.Tr key={label}><Table.Th>{label}</Table.Th><Table.Td>{value}</Table.Td></Table.Tr>)}</Table.Tbody></Table>
          <Group><Button onClick={() => setSelection({ action: 'edit', id })}>Edit source</Button><Button variant="light" onClick={() => setSelection({ action: 'refresh', id })}>Refresh source</Button><Button variant="subtle" color="red" onClick={() => setSelection({ action: 'delete', id })}>Delete source</Button></Group>
          <Text size="sm" c="dimmed">Disabling retains the saved snapshot but removes active memberships. Refresh imports data, not unapplied configuration changes. DNS lookups use RAM only.</Text>
        </Stack></Tabs.Panel>
      </Tabs>
    </> : null}
    {selection ? <ResourceEditor kind="blocklists" selection={selection} onClose={() => setSelection(null)} onComplete={() => { if (selection.action === 'delete') navigate('/blocklists'); else { setSelection(null); change({ after: null }); } }} /> : null}
  </Stack>;
}
