import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { Alert, Badge, Box, Button, Code, Divider, Drawer, Group, Loader, NumberInput, Paper, ScrollArea, Select, Stack, Switch, Table, Text, Textarea, TextInput, Title } from '@mantine/core';
import { useForm } from '@mantine/form';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { ApiError, useApi, useWrite } from '../api';
import type { Schema } from '../api';
import { ErrorNotice, PageHeading } from '../components';

type Domain = Schema<'Domain'>;
type RecordSet = Schema<'Record'>;
type Source = Schema<'Source'>;
type SourceView = Schema<'SourceView'>;
type Resource = Domain | RecordSet | SourceView;
type Kind = 'domains' | 'records' | 'blocklists';
type Page<T> = { items: T[]; next_cursor: string | null; revision: number };
type Snapshot = { data: Resource | Page<Resource>; etag: string };
type Selection = { action: 'create' | 'edit' | 'delete' | 'refresh' | 'refresh-all'; id?: string };
type FormProps<T> = { initial?: T; disabled: boolean; busy: boolean; onSubmit: (body: unknown) => Promise<void> };

const labels = {
  domains: { title: 'Domain rules', singular: 'domain rule', description: 'Exact-name policy. Explicit blocks take precedence over allows and imported lists.' },
  records: { title: 'Local records', singular: 'record set', description: 'Answer A and AAAA questions locally, with ordered addresses and an explicit TTL.' },
  blocklists: { title: 'Blocklist sources', singular: 'source', description: 'Manage source definitions, durable snapshots, and live import health.' },
};

const sourceStates = {
  disabled: { label: 'Disabled', color: 'gray' },
  active: { label: 'Active', color: 'teal' },
  degraded: { label: 'Degraded', color: 'yellow' },
  unavailable: { label: 'Unavailable', color: 'red' },
};

function isIPv4(value: string) {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
}

function isIPv6(value: string) {
  if (!value.includes(':') || !/^[\da-fA-F:.]+$/.test(value)) return false;
  try {
    return new URL(`http://[${value}]/`).hostname.startsWith('[');
  } catch {
    return false;
  }
}

function domainError(value: string): string | null {
  const name = value.endsWith('.') ? value.slice(0, -1) : value;
  if (!name || name.length > 253) return 'Enter a DNS name of 1–253 characters (plus an optional final dot).';
  if (isIPv4(name) || isIPv6(name)) return 'Use a DNS name, not an IP address.';
  if (name.split('.').some((label) => !/^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$/.test(label))) {
    return 'Use ASCII labels of 1–63 characters; no wildcards, spaces, or leading/trailing hyphens.';
  }
  return null;
}

function DomainForm({ initial, disabled, busy, onSubmit }: FormProps<Domain>) {
  const form = useForm({
    initialValues: { domain: initial?.domain ?? '', action: initial?.action ?? 'block' },
    validate: { domain: domainError },
  });
  return (
    <form onSubmit={form.onSubmit(onSubmit)}>
      <Stack>
        <TextInput label="Domain name" description="Exact ASCII name; punycode and underscore labels are supported." placeholder="example.test" required maxLength={254} disabled={busy} {...form.getInputProps('domain')} />
        <Select label="Action" required allowDeselect={false} data={[{ value: 'block', label: 'Block' }, { value: 'allow', label: 'Allow' }]} disabled={busy} {...form.getInputProps('action')} />
        <Text size="sm" c="dimmed">This rule does not match subdomains. Changing the name or action changes its identity.</Text>
        <Button type="submit" disabled={disabled} loading={busy}>{initial ? 'Save rule' : 'Create rule'}</Button>
      </Stack>
    </form>
  );
}

function RecordForm({ initial, disabled, busy, onSubmit }: FormProps<RecordSet>) {
  const form = useForm({
    initialValues: { name: initial?.name ?? '', type: initial?.type ?? 'A', ttl: String(initial?.ttl ?? 60), addresses: initial?.addresses.join('\n') ?? '' },
    validate: {
      name: domainError,
      ttl: (value) => /^\d+$/.test(value) && Number(value) <= 4294967295 ? null : 'Enter an integer from 0 to 4294967295.',
      addresses: (value, values) => {
        const addresses = value.split(/\r?\n/).map((address) => address.trim()).filter(Boolean);
        if (addresses.length < 1 || addresses.length > 16) return 'Enter 1–16 IP addresses, one per line.';
        const valid = values.type === 'A' ? isIPv4 : isIPv6;
        return addresses.every(valid) ? null : `Every address must be an ${values.type === 'A' ? 'IPv4' : 'IPv6'} literal.`;
      },
    },
  });
  return (
    <form onSubmit={form.onSubmit((values) => onSubmit({ name: values.name, type: values.type, ttl: Number(values.ttl), addresses: values.addresses.split(/\r?\n/).map((address) => address.trim()).filter(Boolean) }))}>
      <Stack>
        <TextInput label="Record name" required maxLength={254} placeholder="home.test" disabled={busy} {...form.getInputProps('name')} />
        <Group grow align="start">
          <Select label="Record type" required allowDeselect={false} data={['A', 'AAAA']} disabled={busy} {...form.getInputProps('type')} />
          <TextInput label="TTL (seconds)" required inputMode="numeric" description="0–4294967295" disabled={busy} {...form.getInputProps('ttl')} />
        </Group>
        <Textarea label="Addresses" required description="1–16 matching-family IP literals, one per line. Line order is answer order." autosize minRows={4} maxRows={16} placeholder={form.values.type === 'A' ? '192.0.2.10' : '2001:db8::10'} disabled={busy} {...form.getInputProps('addresses')} />
        <Text size="sm" c="dimmed">Equivalent addresses are deduplicated by the server. Changing the name or type changes the record set identity.</Text>
        <Button type="submit" disabled={disabled} loading={busy}>{initial ? 'Save record set' : 'Create record set'}</Button>
      </Stack>
    </form>
  );
}

function SourceForm({ initial, disabled, busy, onSubmit }: FormProps<Source>) {
  const form = useForm({
    initialValues: { id: initial?.id ?? '', name: initial?.name ?? '', enabled: initial?.enabled ?? true, kind: initial?.source.kind ?? 'url', value: initial?.source.value ?? '', format: initial?.format ?? 'domains' },
    validate: {
      id: (value) => /^[A-Za-z0-9._-]{1,128}$/.test(value) ? null : 'Use 1–128 ASCII letters, digits, dots, underscores, or hyphens.',
      name: (value) => value === '' || /^[\x20-\x7e]{1,256}$/.test(value) ? null : 'Use 1–256 printable ASCII characters, or leave blank.',
      value: (value, values) => {
        if (!value.trim() || value.includes('\0')) return 'Enter a source location.';
        if (values.kind === 'url') {
          try {
            const url = new URL(value);
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return 'Use an HTTP or HTTPS URL.';
          } catch {
            return 'Enter a complete HTTP or HTTPS URL.';
          }
        }
        return null;
      },
      format: (value, values) => values.kind === 'url' && value !== 'domains' ? 'URL sources require domains format.' : null,
    },
  });
  return (
    <form onSubmit={form.onSubmit((values) => onSubmit({ id: values.id, ...(values.name ? { name: values.name } : {}), enabled: values.enabled, source: { kind: values.kind, value: values.value }, format: values.format }))}>
      <Stack>
        <TextInput label="Source ID" required maxLength={128} readOnly={Boolean(initial)} description={initial ? 'Immutable. Create a new source to use a different ID.' : 'A stable identifier: ASCII letters, digits, dots, underscores, and hyphens.'} disabled={busy} {...form.getInputProps('id')} />
        <TextInput label="Display name" description="Optional. Leave blank to use the source ID." maxLength={256} disabled={busy} {...form.getInputProps('name')} />
        <Switch label="Enabled" description="Enabled sources contribute imported block rules." disabled={busy} {...form.getInputProps('enabled', { type: 'checkbox' })} />
        <Select label="Source kind" required allowDeselect={false} data={[{ value: 'url', label: 'HTTP / HTTPS URL' }, { value: 'file', label: 'Local file' }]} value={form.values.kind} disabled={busy} onChange={(value) => { if (value === 'url' || value === 'file') { form.setFieldValue('kind', value); if (value === 'url') form.setFieldValue('format', 'domains'); } }} />
        <TextInput label={form.values.kind === 'url' ? 'Source URL' : 'File path'} required description={form.values.kind === 'url' ? 'Public HTTP/HTTPS destination. Redirects are rejected.' : 'New or changed files must be relative to the server’s configured api.file_root.'} placeholder={form.values.kind === 'url' ? 'https://example.com/domains.txt' : 'lists/domains.txt'} disabled={busy} {...form.getInputProps('value')} />
        <Select label="Format" required allowDeselect={false} data={form.values.kind === 'url' ? [{ value: 'domains', label: 'Domain list' }] : [{ value: 'domains', label: 'Domain list' }, { value: 'hosts', label: 'Hosts file' }]} disabled={busy} {...form.getInputProps('format')} />
        <Text size="sm" c="dimmed">Saving an enabled new or content-changed source loads its contents. Metadata-only edits preserve unchanged operator-owned locations. Provenance is managed by the server.</Text>
        <Button type="submit" disabled={disabled} loading={busy}>{initial ? 'Save source' : 'Create source'}</Button>
      </Stack>
    </form>
  );
}

function SnapshotReview({ snapshot }: { snapshot: Snapshot }) {
  return (
    <Stack gap="xs">
      <Text size="sm" fw={600}>Active state · revision {snapshot.etag}</Text>
      {'items' in snapshot.data ? <Text size="xs" c="dimmed">Showing the first {snapshot.data.items.length} current entries{snapshot.data.next_cursor ? '; more entries exist' : ''}. Your draft has not been changed.</Text> : null}
      <ScrollArea.Autosize mah={260} type="auto">
        <Code block style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{JSON.stringify(snapshot.data, null, 2)}</Code>
      </ScrollArea.Autosize>
    </Stack>
  );
}

function ResourceEditor({ kind, selection, onClose, onComplete }: { kind: Kind; selection: Selection; onClose: () => void; onComplete: () => void }) {
  const api = useApi();
  const writer = useWrite();
  const collectionPath = `/${kind}`;
  const itemPath = selection.id === undefined ? collectionPath : `${collectionPath}/${encodeURIComponent(selection.id)}`;
  const readPath = selection.id === undefined ? `${collectionPath}?limit=100` : itemPath;
  const query = useQuery({ queryKey: [collectionPath, readPath, 'editor'], queryFn: ({ signal }) => api.read<Resource | Page<Resource>>(readPath, signal), retry: false, refetchOnMount: 'always', refetchOnWindowFocus: false });
  const [baseline, setBaseline] = useState<Snapshot | null>(null);
  const [writeError, setWriteError] = useState<unknown>(null);
  const [needsReview, setNeedsReview] = useState(false);
  const [review, setReview] = useState<Snapshot | null>(null);
  const [reviewError, setReviewError] = useState<unknown>(null);

  useEffect(() => {
    if (!baseline && query.isFetchedAfterMount && query.data && !query.isError) setBaseline(query.data);
  }, [baseline, query.isFetchedAfterMount, query.data, query.isError]);

  async function loadReview() {
    setReview(null);
    setReviewError(null);
    const result = await query.refetch();
    if (result.error) setReviewError(result.error);
    else if (result.data) setReview(result.data);
  }

  async function submit(body: unknown) {
    if (!baseline || needsReview || writer.busy) return;
    setWriteError(null);
    const action = selection.action;
    const path = action === 'refresh-all' ? `${collectionPath}/refresh` : action === 'refresh' ? `${itemPath}/refresh` : itemPath;
    const method = action === 'delete' ? 'DELETE' : action === 'edit' ? 'PUT' : 'POST';
    try {
      await writer.submit(path, method, body, baseline.etag);
      onComplete();
    } catch (error) {
      setWriteError(error);
      setNeedsReview(true);
      setReview(null);
    }
  }

  const editing = selection.action === 'edit';
  const creating = selection.action === 'create';
  const deleting = selection.action === 'delete';
  const refreshingAll = selection.action === 'refresh-all';
  const title = `${creating ? 'Create' : editing ? 'Edit' : deleting ? 'Delete' : 'Refresh'} ${refreshingAll ? 'all enabled sources' : labels[kind].singular}`;
  const initial = baseline && !('items' in baseline.data) ? baseline.data : undefined;
  const disabled = needsReview || writer.busy;
  let form: ReactNode = null;
  if (baseline && (creating || editing)) {
    if (kind === 'domains') form = <DomainForm initial={initial as Domain | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
    if (kind === 'records') form = <RecordForm initial={initial as RecordSet | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
    if (kind === 'blocklists') form = <SourceForm initial={initial as Source | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
  }
  return (
    <Drawer opened onClose={() => { if (!writer.busy) onClose(); }} title={<Title order={3}>{title}</Title>} size="lg" position="right" closeOnClickOutside={!writer.busy} closeOnEscape={!writer.busy} withCloseButton={!writer.busy}>
      <Stack>
        {selection.id ? <Text size="sm" c="dimmed" style={{ overflowWrap: 'anywhere' }}>{selection.id}</Text> : null}
        {!baseline && query.isFetching ? <Group role="status"><Loader size="sm" /><Text>Loading current state…</Text></Group> : null}
        {!baseline && query.error ? <><ErrorNotice error={query.error} /><Button variant="default" onClick={() => void query.refetch()}>Retry loading</Button></> : null}
        {writeError ? <ErrorNotice error={writeError} /> : null}
        {needsReview ? (
          <Alert color="yellow" title={writeError instanceof ApiError && writeError.status === 412 ? 'The revision changed. Your draft is preserved.' : 'Review state before another attempt'}>
            <Stack gap="sm">
              <Text size="sm">Nothing is retried automatically. Load the current active state and compare it with your draft. A failed operation may have saved changes without activating them; check operation details before proceeding.</Text>
              <Button variant="default" loading={query.isFetching} onClick={() => void loadReview()}>{review ? 'Reload current state' : 'Load current state for review'}</Button>
              {reviewError ? <ErrorNotice error={reviewError} /> : null}
              {review ? <><SnapshotReview snapshot={review} /><Button variant="outline" disabled={query.isFetching} onClick={() => { setBaseline(review); setNeedsReview(false); setReview(null); setWriteError(null); }}>I reviewed this state — use its revision</Button></> : null}
            </Stack>
          </Alert>
        ) : null}
        {form}
        {baseline && !creating && !editing ? (
          <Stack>
            <SnapshotReview snapshot={baseline} />
            <Alert color={deleting ? 'red' : 'teal'} title={deleting ? 'Confirm deletion' : 'Refresh active definitions'}>
              {deleting ? (kind === 'records' ? 'This removes the entire local record set. An unexpired upstream cache answer may become visible.' : kind === 'blocklists' ? 'This removes the source definition and its saved and live imported memberships. Names supplied by other sources remain blocked.' : 'This removes the explicit rule and may change how this exact name resolves.') : refreshingAll ? 'Fetch every enabled source, then publish prepared updates together. Failed fetches use compatible saved snapshots; sources without one remain unavailable. Unapplied disk edits are not used.' : 'Fetch this source using its active definition. A failed fetch uses a compatible saved snapshot, or leaves the source unavailable if none exists. A disabled source refresh is a no-op.'}
            </Alert>
            <Button color={deleting ? 'red' : 'teal'} disabled={disabled} loading={writer.busy} onClick={() => void submit(undefined)}>{deleting ? 'Confirm delete' : refreshingAll ? 'Refresh all enabled sources' : 'Refresh source'}</Button>
          </Stack>
        ) : null}
        {baseline ? <Text size="xs" c="dimmed">Write precondition: revision {baseline.etag}. Saved and active are confirmed only after the operation completes.</Text> : null}
        <Button variant="subtle" color="gray" disabled={writer.busy} onClick={onClose}>{creating || editing ? 'Cancel editing' : 'Cancel'}</Button>
      </Stack>
    </Drawer>
  );
}

function ResourceCells({ kind, item }: { kind: Kind; item: Resource }) {
  if (kind === 'domains') {
    const domain = item as Domain;
    return <><Table.Td><Text fw={500} style={{ overflowWrap: 'anywhere' }}>{domain.domain}</Text></Table.Td><Table.Td><Badge variant="light" color={domain.action === 'block' ? 'red' : 'teal'}>{domain.action}</Badge></Table.Td></>;
  }
  if (kind === 'records') {
    const record = item as RecordSet;
    return <><Table.Td><Text fw={500} style={{ overflowWrap: 'anywhere' }}>{record.name}</Text></Table.Td><Table.Td><Badge variant="light" color="gray">{record.type}</Badge></Table.Td><Table.Td><Stack gap={2}>{record.addresses.map((address) => <Text key={address} size="sm" style={{ overflowWrap: 'anywhere' }}>{address}</Text>)}</Stack></Table.Td><Table.Td>{record.ttl}s</Table.Td></>;
  }
  const source = item as SourceView;
  const status = source.status;
  const state = sourceStates[status.state];
  return <>
    <Table.Td><Text fw={500} style={{ overflowWrap: 'anywhere' }}>{source.name || source.id}</Text>{source.name ? <Text size="xs" c="dimmed" style={{ overflowWrap: 'anywhere' }}>{source.id}</Text> : null}</Table.Td>
    <Table.Td>
      <Stack gap={2}>
        <Badge variant="light" color={state.color}>{state.label}</Badge>
        {status.state === 'degraded' ? <Text size="xs">Serving a saved snapshot</Text> : status.state === 'unavailable' ? <Text size="xs">Enabled, no compatible snapshot</Text> : null}
        <Text size="xs">{status.domain_count.toLocaleString()} {status.domain_count === 1 ? 'domain' : 'domains'}</Text>
        <Text size="xs" c="dimmed">Last successful import: {status.last_success_at_ms === null ? 'Never' : new Date(status.last_success_at_ms).toLocaleString()}</Text>
        {status.last_error !== null ? <Text size="xs" c={status.state === 'unavailable' ? 'red' : 'yellow'} style={{ overflowWrap: 'anywhere' }}>Last error: {status.last_error}</Text> : null}
      </Stack>
    </Table.Td>
    <Table.Td><Text size="sm" style={{ overflowWrap: 'anywhere' }}>{source.source.value}</Text><Text size="xs" c="dimmed">{source.source.kind} · {source.format} · {source.api_managed ? 'API-managed' : 'Operator-provided'}</Text></Table.Td>
  </>;
}

function CollectionPage({ kind }: { kind: Kind }) {
  const api = useApi();
  const queryClient = useQueryClient();
  const route = `/${kind}`;
  const [limit, setLimit] = useState(50);
  const [filters, setFilters] = useState({ action: '', domain: '' });
  const [cursors, setCursors] = useState<Array<string | null>>([null]);
  const [restarted, setRestarted] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const filterForm = useForm({
    initialValues: { action: '', domain: '', limit: 50 as number | string },
    validate: { domain: (value) => kind === 'domains' && value !== '' ? domainError(value) : null, limit: (value) => typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 100 ? null : 'Choose an integer from 1 to 100.' },
  });
  const params = new URLSearchParams({ limit: String(limit) });
  const cursor = cursors[cursors.length - 1];
  if (cursor) params.set('after', cursor);
  if (kind === 'domains' && filters.action) params.set('action', filters.action);
  if (kind === 'domains' && filters.domain) params.set('domain', filters.domain);
  const path = `${route}?${params.toString()}`;
  const query = useQuery({ queryKey: [route, path], queryFn: ({ signal }) => api.read<Page<Resource>>(path, signal), retry: false });
  const staleCursor = query.error instanceof ApiError && query.error.status === 409 && (query.error.code === 'StaleCursor' || query.error.message === 'StaleCursor');

  useEffect(() => {
    if (staleCursor && cursor) {
      setCursors([null]);
      setRestarted(true);
      void queryClient.invalidateQueries({ queryKey: [route] });
    }
  }, [staleCursor, cursor, queryClient, route]);

  function reload() {
    setCursors([null]);
    setRestarted(false);
    void queryClient.invalidateQueries({ queryKey: [route] });
  }

  const page = query.data?.data;
  const headings = kind === 'domains' ? ['Domain name', 'Action'] : kind === 'records' ? ['Record name', 'Type', 'Addresses', 'TTL'] : ['Source', 'State', 'Location / format'];
  return (
    <Stack gap="lg">
      <PageHeading title={labels[kind].title} description={labels[kind].description} />
      <Group justify="space-between" align="center">
        <Group gap="xs">
          <Button onClick={() => setSelection({ action: 'create' })}>Add {labels[kind].singular}</Button>
          {kind === 'blocklists' ? <Button variant="light" onClick={() => setSelection({ action: 'refresh-all' })}>Refresh all sources</Button> : null}
        </Group>
        <Button variant="default" loading={query.isFetching} onClick={reload}>Reload listing</Button>
      </Group>
      <Paper withBorder p="md">
        <form onSubmit={filterForm.onSubmit((values) => { setFilters({ action: values.action, domain: values.domain }); setLimit(Number(values.limit)); setCursors([null]); setRestarted(false); })}>
          <Group align="start" gap="sm">
            {kind === 'domains' ? <><Select label="Action" data={[{ value: '', label: 'All actions' }, { value: 'block', label: 'Block' }, { value: 'allow', label: 'Allow' }]} allowDeselect={false} w={155} {...filterForm.getInputProps('action')} /><TextInput label="Exact domain name" placeholder="All names" maxLength={254} style={{ flex: '1 1 220px' }} {...filterForm.getInputProps('domain')} /></> : null}
            <NumberInput label="Rows per page" min={1} max={100} allowDecimal={false} allowNegative={false} w={140} {...filterForm.getInputProps('limit')} />
            <Button type="submit" variant="light" mt={25}>{kind === 'domains' ? 'Apply filters' : 'Apply limit'}</Button>
            {kind === 'domains' && (filters.action || filters.domain) ? <Button variant="subtle" mt={25} onClick={() => { filterForm.setValues({ action: '', domain: '' }); setFilters({ action: '', domain: '' }); setCursors([null]); setRestarted(false); }}>Clear filters</Button> : null}
          </Group>
        </form>
      </Paper>
      {restarted ? <Alert color="yellow" title="Listing restarted" withCloseButton onClose={() => setRestarted(false)}>The server revision changed, so the old cursor expired. This listing starts again at the first page.</Alert> : null}
      {query.error && !staleCursor ? <ErrorNotice error={query.error} /> : null}
      {query.isPending ? <Group role="status"><Loader size="sm" /><Text>Loading {labels[kind].title.toLowerCase()}…</Text></Group> : null}
      {page && !query.isError ? (
        <Box>
          {page.items.length ? (
            <Table.ScrollContainer minWidth={kind === 'records' || kind === 'blocklists' ? 760 : 580}>
              <Table verticalSpacing="sm" horizontalSpacing="sm" highlightOnHover withTableBorder>
                <Table.Thead><Table.Tr>{headings.map((heading) => <Table.Th key={heading}>{heading}</Table.Th>)}<Table.Th ta="right">Actions</Table.Th></Table.Tr></Table.Thead>
                <Table.Tbody>{page.items.map((item) => (
                  <Table.Tr key={item.id}>
                    <ResourceCells kind={kind} item={item} />
                    <Table.Td><Group gap={4} justify="flex-end" wrap="nowrap">
                      <Button size="compact-sm" variant="subtle" aria-label={`Edit ${item.id}`} onClick={() => setSelection({ action: 'edit', id: item.id })}>Edit</Button>
                      {kind === 'blocklists' ? <Button size="compact-sm" variant="subtle" aria-label={`Refresh ${item.id}`} onClick={() => setSelection({ action: 'refresh', id: item.id })}>Refresh</Button> : null}
                      <Button size="compact-sm" variant="subtle" color="red" aria-label={`Delete ${item.id}`} onClick={() => setSelection({ action: 'delete', id: item.id })}>Delete</Button>
                    </Group></Table.Td>
                  </Table.Tr>
                ))}</Table.Tbody>
              </Table>
            </Table.ScrollContainer>
          ) : <Stack py="xl" gap="xs"><Title order={3}>{filters.action || filters.domain ? 'No matching domain rules' : `No ${labels[kind].title.toLowerCase()} yet`}</Title><Text c="dimmed">{filters.action || filters.domain ? 'Change the exact-name or action filter to see other rules.' : kind === 'blocklists' ? 'Add a URL or local file source. This view lists definitions, not individual imported names.' : kind === 'records' ? 'Add a record set to resolve an exact name directly from this server.' : 'Add an exact-name allow or block rule to control local policy.'}</Text></Stack>}
          <Divider my="md" />
          <Group justify="space-between">
            <Text size="sm" c="dimmed" aria-live="polite">Page {cursors.length} · {page.items.length} {page.items.length === 1 ? 'entry' : 'entries'} · revision {page.revision}</Text>
            <Group gap="xs">
              <Button variant="default" disabled={cursors.length === 1 || query.isFetching} onClick={() => setCursors((current) => current.slice(0, -1))}>Back</Button>
              <Button variant="default" disabled={!page.next_cursor || query.isFetching} onClick={() => { if (page.next_cursor) setCursors((current) => [...current, page.next_cursor]); }}>Next</Button>
            </Group>
          </Group>
        </Box>
      ) : null}
      {kind === 'blocklists' ? <Text size="sm" c="dimmed">Refresh is not configuration reload. Restart and refresh fetch first, falling back only to a compatible saved snapshot. DNS lookups use RAM. Disabling retains the saved snapshot; deleting removes it.</Text> : null}
      {selection ? <ResourceEditor key={`${selection.action}:${selection.id ?? ''}`} kind={kind} selection={selection} onClose={() => setSelection(null)} onComplete={() => { setSelection(null); setCursors([null]); setRestarted(false); }} /> : null}
    </Stack>
  );
}

export function DomainsPage() {
  return <CollectionPage kind="domains" />;
}

export function RecordsPage() {
  return <CollectionPage kind="records" />;
}

export function BlocklistsPage() {
  return <CollectionPage kind="blocklists" />;
}
