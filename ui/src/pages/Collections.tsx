import { useEffect, useState } from 'react';
import type { ReactNode } from 'react';
import { Alert, Badge, Box, Button, Code, Divider, Drawer, Group, Loader, NumberInput, Paper, ScrollArea, Select, Stack, Switch, Table, Text, Textarea, TextInput, Title } from '@mantine/core';
import { useForm } from '@mantine/form';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useSearchParams } from 'react-router-dom';
import { DomainLink } from '../DomainInspection';
import { ApiError, RawJson, useApi, useWrite } from '../api';
import type { Schema } from '../api';
import { ErrorNotice, PageHeading } from '../components';

type Domain = Schema<'Domain'>;
type RecordSet = Schema<'Record'>;
type Source = Schema<'Source'>;
type SourceView = Schema<'SourceView'>;
type Resource = Domain | RecordSet | SourceView;
type Kind = 'domains' | 'records' | 'blocklists';
type Page<T> = { items: T[]; next_cursor: string | null; revision: number };
type Snapshot = { data: Resource | Page<Resource> | Schema<'Config'>; etag: string; raw: string };
type Selection = { action: 'create' | 'edit' | 'delete' | 'refresh' | 'refresh-all' | 'global-refresh'; id?: string };
type FormProps<T> = { initial?: T; disabled: boolean; busy: boolean; onSubmit: (body: unknown) => Promise<void> };

const labels = {
  domains: { title: 'Domain rules', singular: 'domain rule', description: 'Exact-name policy. Explicit blocks take precedence over allows and imported lists.' },
  records: { title: 'Local records', singular: 'record set', description: 'Answer A and AAAA questions locally, with ordered addresses and an explicit TTL.' },
  blocklists: { title: 'Blocklist sources', singular: 'source', description: 'Manage source definitions, durable snapshots, and live import health.' },
};

const sourceStates = {
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

function DomainForm({ initial, disabled, busy, onSubmit, prefill }: FormProps<Domain> & { prefill?: { domain: string; action: 'allow' | 'block' } }) {
  const form = useForm({
    initialValues: { domain: initial?.domain ?? prefill?.domain ?? '', action: initial?.action ?? prefill?.action ?? 'block' },
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

const refreshFields = [
  { key: 'interval_seconds', label: 'Interval (seconds)', fallback: 86400, min: 1, max: 4294967295 },
  { key: 'jitter_percent', label: 'Jitter (%)', fallback: 10, min: 0, max: 100 },
  { key: 'retry_initial_seconds', label: 'Initial retry (seconds)', fallback: 300, min: 1, max: 4294967295 },
  { key: 'retry_max_seconds', label: 'Maximum retry (seconds)', fallback: 21600, min: 1, max: 4294967295 },
] as const;

export function importTime(value: number | null) {
  return value === null ? 'None' : new Date(value).toLocaleString();
}

export function SourceImportStatus({ source }: { source: SourceView }) {
  const status = source.status;
  const state = sourceStates[status.state];
  return <Stack gap={2}>
    <Group gap="xs"><Badge variant="light" color={source.enabled ? 'blue' : 'gray'}>{source.enabled ? 'Enabled' : 'Disabled'}</Badge><Badge variant="light" color={state.color}>Import: {state.label}</Badge>{status.refreshing ? <Badge variant="light">Refreshing</Badge> : null}</Group>
    <Text size="xs">{status.active_domain_count.toLocaleString()} active / {status.snapshot_domain_count.toLocaleString()} snapshot domains</Text>
    <Text size="xs" c="dimmed">Last attempt: {importTime(status.last_attempt_at_ms)}</Text>
    <Text size="xs" c="dimmed">Last completed: {importTime(status.last_completed_at_ms)}</Text>
    <Text size="xs" c="dimmed">Last success: {importTime(status.last_success_at_ms)}</Text>
    <Text size="xs" c="dimmed">Next refresh: {importTime(status.next_refresh_at_ms)} · Consecutive failures: {status.consecutive_failures}</Text>
    {status.last_error !== null ? <Text size="xs" c={status.state === 'unavailable' ? 'red' : 'yellow'} style={{ overflowWrap: 'anywhere' }}>Last error: {status.last_error}</Text> : null}
  </Stack>;
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
        <Text size="sm" c="dimmed">All sources use the global refresh settings on the Blocklists page, including disabled sources. Saving metadata does not fetch contents. New or content-changed sources import even when disabled, updating saved snapshots without contributing DNS rules.</Text>
        <Button type="submit" disabled={disabled} loading={busy}>{initial ? 'Save source' : 'Create source'}</Button>
      </Stack>
    </form>
  );
}

function RefreshPolicyForm({ initial, disabled, busy, onSubmit }: FormProps<Schema<'Config'>>) {
  const policy = initial?.blocks?.refresh;
  const form = useForm({
    initialValues: {
      enabled: policy?.enabled ?? true,
      interval_seconds: policy?.interval_seconds ?? 86400,
      jitter_percent: policy?.jitter_percent ?? 10,
      retry_initial_seconds: policy?.retry_initial_seconds ?? 300,
      retry_max_seconds: policy?.retry_max_seconds ?? 21600,
    },
    validate: (values) => {
      const errors: Record<string, string> = {};
      for (const field of refreshFields) {
        const value = values[field.key];
        if (!Number.isInteger(value) || value < field.min || value > field.max) errors[field.key] = `Enter an integer from ${field.min} to ${field.max}.`;
      }
      if (values.retry_max_seconds < values.retry_initial_seconds) errors.retry_max_seconds = 'Maximum retry must be at least the initial retry.';
      return errors;
    },
  });
  return <form onSubmit={form.onSubmit(onSubmit)}><Stack>
    <Text size="sm">One global policy applies to every blocklist. Disabled lists still import and save snapshots, but never contribute active DNS memberships. Turning scheduling off does not disable manual refresh or startup imports.</Text>
    <Switch label="Enable scheduled refresh for all lists" disabled={busy} {...form.getInputProps('enabled', { type: 'checkbox' })} />
    {refreshFields.map(field => <NumberInput key={field.key} label={field.label} description={`Default: ${field.fallback}`} required min={field.min} max={field.max} allowDecimal={false} disabled={busy} {...form.getInputProps(field.key)} />)}
    <Text size="sm" c="dimmed">Saves only the global refresh policy within the viewed configuration, preserving every other setting and collection. Schedule changes do not fetch source contents.</Text>
    <Button type="submit" disabled={disabled} loading={busy}>Save global refresh settings</Button>
  </Stack></form>;
}

function withRefreshPolicy(raw: string, policy: unknown): RawJson {
  // Replace only blocks.refresh in the raw document so unrelated usize values
  // retain their exact integer tokens rather than rounding through JavaScript.
  function replaceMember(text: string, path: string[], value: string): string {
    const tokens = Array.from(text.matchAll(/"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^\s{}\[\],:]+/g));
    let depth = 0;
    for (let index = 0; index < tokens.length; index++) {
      const token = tokens[index][0];
      if (depth === 1 && token.startsWith('"') && tokens[index + 1]?.[0] === ':' && JSON.parse(token) === path[0]) {
        const start = index + 2;
        let end = start;
        if (tokens[start][0] === '{' || tokens[start][0] === '[') {
          let nested = 0;
          do {
            if (tokens[end][0] === '{' || tokens[end][0] === '[') nested++;
            else if (tokens[end][0] === '}' || tokens[end][0] === ']') nested--;
            end++;
          } while (nested > 0);
          end--;
        }
        const from = tokens[start].index!;
        const to = tokens[end].index! + tokens[end][0].length;
        const replacement = path.length === 1 ? value : replaceMember(text.slice(from, to), path.slice(1), value);
        return text.slice(0, from) + replacement + text.slice(to);
      }
      if (token === '{' || token === '[') depth++;
      else if (token === '}' || token === ']') depth--;
    }
    const closing = tokens[tokens.length - 1].index!;
    const replacement = path.length === 1 ? value : replaceMember('{}', path.slice(1), value);
    return `${text.slice(0, closing)}${tokens.length > 2 ? ',' : ''}${JSON.stringify(path[0])}:${replacement}${text.slice(closing)}`;
  }
  return new RawJson(replaceMember(raw, ['blocks', 'refresh'], JSON.stringify(policy)));
}

function SnapshotReview({ snapshot }: { snapshot: Snapshot }) {
  return (
    <Stack gap="xs">
      <Text size="sm" fw={600}>Active state · revision {snapshot.etag}</Text>
      {'items' in snapshot.data ? <Text size="xs" c="dimmed">Showing the first {snapshot.data.items.length} current entries{snapshot.data.next_cursor ? '; more entries exist' : ''}. Your draft has not been changed.</Text> : null}
      <ScrollArea.Autosize mah={260} type="auto">
        <Code block style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{'schema_version' in snapshot.data ? snapshot.raw : JSON.stringify(snapshot.data, null, 2)}</Code>
      </ScrollArea.Autosize>
    </Stack>
  );
}

export function ResourceEditor({ kind, selection, onClose, onComplete, prefill }: { kind: Kind; selection: Selection; onClose: () => void; onComplete: () => void; prefill?: { domain: string; action: 'allow' | 'block' } }) {
  const api = useApi();
  const writer = useWrite();
  const globalRefresh = selection.action === 'global-refresh';
  const collectionPath = globalRefresh ? '/config' : `/${kind}`;
  const itemPath = selection.id === undefined ? collectionPath : `${collectionPath}/${encodeURIComponent(selection.id)}`;
  const readPath = globalRefresh ? collectionPath : selection.id === undefined ? `${collectionPath}?limit=100` : itemPath;
  const query = useQuery({ queryKey: [collectionPath, readPath, 'editor'], queryFn: ({ signal }) => api.read<Snapshot['data']>(readPath, signal), retry: false, refetchOnMount: 'always', refetchOnWindowFocus: false });
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
    const method = action === 'delete' ? 'DELETE' : action === 'edit' || globalRefresh ? 'PUT' : 'POST';
    try {
      await writer.submit(path, method, globalRefresh ? withRefreshPolicy(baseline.raw, body) : body, baseline.etag);
      onComplete();
    } catch (error) {
      setWriteError(error);
      setNeedsReview(true);
      setReview(null);
    }
  }

  const editing = selection.action === 'edit' || globalRefresh;
  const creating = selection.action === 'create';
  const deleting = selection.action === 'delete';
  const refreshingAll = selection.action === 'refresh-all';
  const title = globalRefresh ? 'Global refresh settings' : `${creating ? 'Create' : editing ? 'Edit' : deleting ? 'Delete' : 'Refresh'} ${refreshingAll ? 'all sources' : labels[kind].singular}`;
  const initial = baseline && !('items' in baseline.data) ? baseline.data : undefined;
  const disabled = needsReview || writer.busy;
  let form: ReactNode = null;
  if (baseline && (creating || editing)) {
    if (kind === 'domains') form = <DomainForm initial={initial as Domain | undefined} prefill={creating ? prefill : undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
    if (kind === 'records') form = <RecordForm initial={initial as RecordSet | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
    if (globalRefresh) form = <RefreshPolicyForm initial={initial as Schema<'Config'> | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
    else if (kind === 'blocklists') form = <SourceForm initial={initial as Source | undefined} disabled={disabled} busy={writer.busy} onSubmit={submit} />;
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
              {deleting ? (kind === 'records' ? 'This removes the entire local record set. An unexpired upstream cache answer may become visible.' : kind === 'blocklists' ? 'This removes the source definition and its saved and live imported memberships. Names supplied by other sources remain blocked.' : 'This removes the explicit rule and may change how this exact name resolves.') : refreshingAll ? 'Fetch every source, including disabled sources, regardless of whether global scheduling is enabled, then publish prepared updates together. Failed imports retain compatible last-known-good data indefinitely and schedule retries when global scheduling is enabled. Unapplied disk edits are not used.' : 'Fetch this source using its active definition, even when disabled or global scheduling is off. Failed imports retain compatible last-known-good data indefinitely. Disabled sources update saved contents without contributing DNS rules.'}
            </Alert>
            <Button color={deleting ? 'red' : 'teal'} disabled={disabled} loading={writer.busy} onClick={() => void submit(undefined)}>{deleting ? 'Confirm delete' : refreshingAll ? 'Refresh all sources' : 'Refresh source'}</Button>
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
    return <><Table.Td><DomainLink domain={domain.domain} /></Table.Td><Table.Td><Badge variant="light" color={domain.action === 'block' ? 'red' : 'teal'}>{domain.action}</Badge></Table.Td></>;
  }
  if (kind === 'records') {
    const record = item as RecordSet;
    return <><Table.Td><DomainLink domain={record.name} type={record.type === 'A' ? 1 : 28} /></Table.Td><Table.Td><Badge variant="light" color="gray">{record.type}</Badge></Table.Td><Table.Td><Stack gap={2}>{record.addresses.map((address) => <Text key={address} size="sm" style={{ overflowWrap: 'anywhere' }}>{address}</Text>)}</Stack></Table.Td><Table.Td>{record.ttl}s</Table.Td></>;
  }
  const source = item as SourceView;
  return <>
    <Table.Td><Link to={`/blocklists/${encodeURIComponent(source.id)}`}>{source.name || source.id}</Link>{source.name ? <Text size="xs" c="dimmed" style={{ overflowWrap: 'anywhere' }}>{source.id}</Text> : null}<Text size="sm" mt={4}><Link to={`/blocklists/${encodeURIComponent(source.id)}`}>View domains</Link></Text></Table.Td>
    <Table.Td>
      <SourceImportStatus source={source} />
    </Table.Td>
    <Table.Td><Text size="sm" style={{ overflowWrap: 'anywhere' }}>{source.source.value}</Text><Text size="xs" c="dimmed">{source.source.kind} · {source.format} · {source.api_managed ? 'API-managed' : 'Operator-provided'}</Text></Table.Td>
  </>;
}

function CollectionPage({ kind }: { kind: Kind }) {
  const api = useApi();
  const queryClient = useQueryClient();
  const route = `/${kind}`;
  const [search, setSearch] = useSearchParams();
  const rawLimit = Number(search.get('limit') ?? 50);
  const limit = Number.isInteger(rawLimit) && rawLimit >= 1 && rawLimit <= 100 ? rawLimit : 50;
  const filters = { action: search.get('action') ?? '', domain: search.get('domain') ?? '' };
  const cursor = search.get('after');
  const [restarted, setRestarted] = useState(false);
  const [selection, setSelection] = useState<Selection | null>(null);
  const createAllow = kind === 'domains' && search.get('create') === 'allow';
  const activeSelection: Selection | null = selection ?? (createAllow ? { action: 'create' } : null);
  const filterForm = useForm({
    initialValues: { ...filters, limit: limit as number | string },
    validate: { domain: (value) => kind === 'domains' && value !== '' ? domainError(value) : null, limit: (value) => typeof value === 'number' && Number.isInteger(value) && value >= 1 && value <= 100 ? null : 'Choose an integer from 1 to 100.' },
  });
  useEffect(() => { filterForm.setValues({ action: search.get('action') ?? '', domain: search.get('domain') ?? '', limit }); }, [search, limit]);
  function updateListing(values: { action?: string; domain?: string; limit?: number; after?: string | null }, replace = false) {
    const next = new URLSearchParams(search);
    for (const [key, value] of Object.entries(values)) { if (value) next.set(key, String(value)); else next.delete(key); }
    if (!('after' in values) || values.after === null) { next.delete('after'); next.delete('previous'); }
    setSearch(next, { replace });
  }
  function closeEditor() { setSelection(null); if (createAllow) { const next = new URLSearchParams(search); next.delete('create'); setSearch(next, { replace: true }); } }
  const params = new URLSearchParams({ limit: String(limit) });
  if (cursor) params.set('after', cursor);
  if (kind === 'domains' && filters.action) params.set('action', filters.action);
  if (kind === 'domains' && filters.domain) params.set('domain', filters.domain);
  const path = `${route}?${params.toString()}`;
  const query = useQuery({ queryKey: [route, path], queryFn: ({ signal }) => api.read<Page<Resource>>(path, signal), retry: false, refetchInterval: kind === 'blocklists' && !cursor ? 5000 : false });
  const staleCursor = query.error instanceof ApiError && query.error.status === 409 && (query.error.code === 'StaleCursor' || query.error.message === 'StaleCursor');

  useEffect(() => {
    if (staleCursor && cursor) {
      const next = new URLSearchParams(search); next.delete('after'); next.delete('previous'); setSearch(next, { replace: true });
      setRestarted(true);
      void queryClient.invalidateQueries({ queryKey: [route] });
    }
  }, [staleCursor, cursor, queryClient, route, search, setSearch]);

  function reload() {
    updateListing({ after: null });
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
      {kind === 'blocklists' ? <section aria-label="Global refresh settings"><Group gap="sm"><Button variant="default" onClick={() => setSelection({ action: 'global-refresh' })}>Global refresh settings</Button><Text size="sm" c="dimmed">Applies to all lists, including imports for disabled lists.</Text></Group></section> : null}
      <Paper withBorder p="md">
        <form onSubmit={filterForm.onSubmit((values) => { updateListing({ action: values.action, domain: values.domain, limit: Number(values.limit) }); setRestarted(false); })}>
          <Group align="start" gap="sm">
            {kind === 'domains' ? <><Select label="Action" data={[{ value: '', label: 'All actions' }, { value: 'block', label: 'Block' }, { value: 'allow', label: 'Allow' }]} allowDeselect={false} w={155} {...filterForm.getInputProps('action')} /><TextInput label="Exact domain name" placeholder="All names" maxLength={254} style={{ flex: '1 1 220px' }} {...filterForm.getInputProps('domain')} /></> : null}
            <NumberInput label="Rows per page" min={1} max={100} allowDecimal={false} allowNegative={false} w={140} {...filterForm.getInputProps('limit')} />
            <Button type="submit" variant="light" mt={25}>{kind === 'domains' ? 'Apply filters' : 'Apply limit'}</Button>
            {kind === 'domains' && (filters.action || filters.domain) ? <Button variant="subtle" mt={25} onClick={() => { filterForm.setValues({ action: '', domain: '' }); updateListing({ action: '', domain: '' }); setRestarted(false); }}>Clear filters</Button> : null}
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
            <Text size="sm" c="dimmed" aria-live="polite">{cursor ? 'Continued page' : 'First page'} · {page.items.length} {page.items.length === 1 ? 'entry' : 'entries'} · revision {page.revision}</Text>
            <Group gap="xs">
              <Button variant="default" disabled={!cursor || query.isFetching} onClick={() => { const next = new URLSearchParams(search); const previous = next.getAll('previous'); const after = previous.pop(); next.delete('previous'); previous.forEach(value => next.append('previous', value)); if (after) next.set('after', after); else next.delete('after'); setSearch(next); }}>Back</Button>
              <Button variant="default" disabled={!page.next_cursor || query.isFetching} onClick={() => { if (page.next_cursor) { const next = new URLSearchParams(search); next.append('previous', cursor ?? ''); next.set('after', page.next_cursor); setSearch(next); } }}>Next</Button>
            </Group>
          </Group>
        </Box>
      ) : null}
      {kind === 'blocklists' ? <Text size="sm" c="dimmed">Refresh is not configuration reload. Restart and refresh fetch first, falling back only to a compatible saved snapshot. DNS lookups use RAM. Disabling retains the saved snapshot; deleting removes it.</Text> : null}
      {activeSelection ? <ResourceEditor key={`${activeSelection.action}:${activeSelection.id ?? ''}`} kind={kind} selection={activeSelection} prefill={createAllow ? { domain: filters.domain, action: 'allow' } : undefined} onClose={closeEditor} onComplete={() => { setSelection(null); const next = new URLSearchParams(search); next.delete('create'); next.delete('after'); next.delete('previous'); setSearch(next, { replace: true }); setRestarted(false); }} /> : null}
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
