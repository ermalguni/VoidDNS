import { useState } from 'react';
import { Alert, Badge, Button, Checkbox, Code, Divider, Fieldset, Group, JsonInput, Loader, Modal, Select, SimpleGrid, Stack, Table, Text, TextInput, Title } from '@mantine/core';
import { useQuery } from '@tanstack/react-query';
import { useBeforeUnload, useBlocker } from 'react-router-dom';
import { ApiError, RawJson, useApi, useWrite, type Schema } from '../api';
import { ErrorNotice, PageHeading } from '../components';

type Snapshot<T> = { data: T; etag: string; raw: string };

function formatJson(raw: string): string {
  // Validate syntax, but never serialize parsed numbers: usize can exceed JS precision.
  try { JSON.parse(raw); } catch { return raw; }
  const tokens = raw.match(/"(?:[^"\\]|\\.)*"|[{}\[\],:]|[^\s{}\[\],:]+/g) ?? [];
  const output: string[] = [];
  let depth = 0;
  const newline = () => output.push('\n', '  '.repeat(depth));
  tokens.forEach((token, index) => {
    if (token === '{' || token === '[') {
      output.push(token);
      depth++;
      if (tokens[index + 1] !== '}' && tokens[index + 1] !== ']') newline();
    } else if (token === '}' || token === ']') {
      depth--;
      if (tokens[index - 1] !== '{' && tokens[index - 1] !== '[') newline();
      output.push(token);
    } else if (token === ',') {
      output.push(token);
      newline();
    } else {
      output.push(token === ':' ? ': ' : token);
    }
  });
  return output.join('');
}

function DraftGuard({ dirty }: { dirty: boolean }) {
  const blocker = useBlocker(dirty);
  useBeforeUnload((event) => {
    if (dirty) {
      event.preventDefault();
      event.returnValue = '';
    }
  });
  return <Modal opened={blocker.state === 'blocked'} onClose={() => { if (blocker.state === 'blocked') blocker.reset(); }} title="Leave with unsaved changes?">
    <Stack><Text>Your editor draft will be lost if you leave this page.</Text><Group justify="flex-end"><Button variant="default" onClick={() => { if (blocker.state === 'blocked') blocker.reset(); }}>Keep editing</Button><Button color="red" onClick={() => { if (blocker.state === 'blocked') blocker.proceed(); }}>Discard draft and leave</Button></Group></Stack>
  </Modal>;
}
function RevisionReview({ raw, etag, onAccept, busy }: { raw: string; etag: string; onAccept: () => void; busy: boolean }) {
  const [reviewed, setReviewed] = useState(false);
  return <Stack gap="sm">
    <Text size="sm">Current active state · revision <Code>{etag}</Code>. Compare it with your draft before continuing. Keeping your draft will replace these values on the next save.</Text>
    <Code block style={{ maxHeight: 300, overflow: 'auto', whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{formatJson(raw)}</Code>
    <Checkbox label="I reviewed the current active state and want to keep my draft." checked={reviewed} onChange={(event) => setReviewed(event.currentTarget.checked)} />
    <Button variant="light" disabled={!reviewed || busy} onClick={onAccept}>Use reviewed revision, keep draft</Button>
  </Stack>;
}

export function OverviewPage() {
  const api = useApi();
  const writer = useWrite();
  const status = useQuery({ queryKey: ['/status'], queryFn: ({ signal }) => api.read<Schema<'Status'>>('/status', signal), refetchInterval: 10000 });
  const cache = useQuery({ queryKey: ['/cache'], queryFn: ({ signal }) => api.read<Schema<'Cache'>>('/cache', signal), refetchInterval: 10000 });
  const [confirmation, setConfirmation] = useState<Snapshot<Schema<'Cache'>> | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [cleared, setCleared] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  async function clearCache() {
    if (!confirmation) return;
    setError(null);
    setCleared(false);
    try {
      await writer.submit('/cache/entries', 'DELETE', undefined, confirmation.etag);
      setConfirmation(null);
      setCleared(true);
    } catch (failure) {
      setError(failure);
      setConfirmation(null);
      void cache.refetch();
    }
  }
  return <Stack gap="xl">
    <PageHeading title="Overview" description="The current listener, configuration agreement, and upstream response cache." />
    <Group justify="space-between"><Text size="sm" c="dimmed">Refreshes every 10 seconds while this page is open.</Text><Button variant="default" loading={status.isFetching || cache.isFetching} onClick={() => { void status.refetch(); void cache.refetch(); }}>Refresh status</Button></Group>
    <ErrorNotice error={status.error || cache.error || error} />
    {cleared && <Alert color="teal" title="Cache cleared">All upstream response-cache entries were cleared. Policies and local records were not changed.</Alert>}
    <section aria-labelledby="listener-heading">
      <Title id="listener-heading" order={2} size="h3" mb="md">Listener & runtime</Title>
      {status.isPending ? <Loader size="sm" aria-label="Loading status" /> : status.data ? <>
        <Group mb="md"><Badge color={status.data.data.dns.ready ? 'teal' : 'orange'} variant="light">{status.data.data.dns.ready ? 'Listener ready' : 'Listener not ready'}</Badge><Text size="sm">{status.data.data.dns.listen}</Text></Group>
        <Table withRowBorders><Table.Tbody>
          <Table.Tr><Table.Th>Worker generation</Table.Th><Table.Td>{String(status.data.data.dns.generation)}</Table.Td></Table.Tr>
          <Table.Tr><Table.Th>Global revision</Table.Th><Table.Td><Code>{status.data.etag}</Code></Table.Td></Table.Tr>
          <Table.Tr><Table.Th>Current operation</Table.Th><Table.Td>{status.data.data.operation_id === null ? 'None' : `Operation ${status.data.data.operation_id}`}</Table.Td></Table.Tr>
          <Table.Tr><Table.Th>Saved / active agreement</Table.Th><Table.Td>{status.data.data.saved_matches_active === null ? 'Unknown while an operation is running' : status.data.data.saved_matches_active ? 'Last known to match' : 'Saved and active configuration differ'}</Table.Td></Table.Tr>
        </Table.Tbody></Table>
        <Text size="sm" c="dimmed" mt="sm">Readiness describes the DNS listener, not upstream health. Agreement is last known by this process; external file edits are not detected.</Text>
        {status.data.data.saved_matches_active === false && <Alert color="orange" mt="md" title="Inspect before making another change">An operation may have saved a candidate that did not activate. The configuration editor shows the active document, not the contents of the file on disk.</Alert>}
      </> : null}
    </section>
    <Divider />
    <section aria-labelledby="cache-heading">
      <Group justify="space-between" mb="md"><Title id="cache-heading" order={2} size="h3">Upstream response cache</Title><Button variant="default" disabled={!cache.data || writer.busy} loading={refreshing} onClick={async () => {
        setRefreshing(true); setError(null); setCleared(false);
        try { setConfirmation(await api.read<Schema<'Cache'>>('/cache')); } catch (failure) { setError(failure); } finally { setRefreshing(false); }
      }}>Clear cache…</Button></Group>
      {cache.isPending ? <Loader size="sm" aria-label="Loading cache" /> : cache.data ? <Table><Table.Tbody>
        <Table.Tr><Table.Th>Capacity</Table.Th><Table.Td>{integerToken(cache.data.raw, 'capacity', cache.data.data.capacity)} slots{cache.data.data.capacity === 0 ? ' · caching disabled' : ''}</Table.Td></Table.Tr>
        <Table.Tr><Table.Th>Occupied slots</Table.Th><Table.Td>{integerToken(cache.data.raw, 'occupied_slots', cache.data.data.occupied_slots)}</Table.Td></Table.Tr>
      </Table.Tbody></Table> : null}
      <Text size="sm" c="dimmed" mt="sm">Occupied slots can include expired entries awaiting reclamation. They are not hit/miss statistics.</Text>
    </section>
    <Modal opened={confirmation !== null} onClose={() => { if (!writer.busy) setConfirmation(null); }} title="Clear all upstream cache entries?" closeOnClickOutside={!writer.busy} closeOnEscape={!writer.busy} withCloseButton={!writer.busy}>
      <Stack><Text>This immediately clears cached upstream responses. It does not remove explicit rules, imported blocklists, or local records.</Text><Text size="sm">Viewed revision: <Code>{confirmation?.etag}</Code>. Occupied slots: {confirmation ? integerToken(confirmation.raw, 'occupied_slots', confirmation.data.occupied_slots) : '—'}.</Text><Group justify="flex-end"><Button variant="default" disabled={writer.busy} onClick={() => setConfirmation(null)}>Cancel</Button><Button color="red" loading={writer.busy} onClick={() => void clearCache()}>Clear cache</Button></Group></Stack>
    </Modal>
  </Stack>;
}

function integerToken(raw: string, field: string, fallback: number) {
  return new RegExp(`"${field}"\\s*:\\s*(\\d+)`).exec(raw)?.[1] ?? String(fallback);
}

type SettingsDraft = {
  address: string;
  port: string;
  maxConnections: string;
  idleTimeout: string;
  readTimeout: string;
  writeTimeout: string;
  servers: { address: string; port: string }[];
  timeout: string;
  capacity: string;
  minPositiveTtl: string;
  level: 'err' | 'warn' | 'info' | 'debug';
};

function settingsDraft(snapshot: Snapshot<Schema<'Settings'>>): SettingsDraft {
  const settings = snapshot.data;
  return {
    address: settings.dns.listen?.address ?? '127.0.0.1',
    port: String(settings.dns.listen?.port ?? 53),
    maxConnections: String(settings.dns.tcp?.max_connections ?? 64),
    idleTimeout: String(settings.dns.tcp?.idle_timeout_ms ?? 10000),
    readTimeout: String(settings.dns.tcp?.read_timeout_ms ?? 5000),
    writeTimeout: String(settings.dns.tcp?.write_timeout_ms ?? 5000),
    servers: settings.upstream.servers.map((server) => ({ address: server.address, port: String(server.port ?? 53) })),
    timeout: String(settings.upstream.timeout_ms ?? 3000),
    capacity: integerToken(snapshot.raw, 'capacity', settings.cache.capacity ?? 4096),
    minPositiveTtl: String(settings.cache.min_positive_ttl_seconds ?? 0),
    level: settings.logging.level ?? 'info',
  };
}

function ipv4(value: string) {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part) => /^(0|[1-9]\d{0,2})$/.test(part) && Number(part) <= 255);
}

function integer(value: string, min: number, max?: number) {
  return /^(0|[1-9]\d*)$/.test(value) && BigInt(value) >= BigInt(min) && (max === undefined || BigInt(value) <= BigInt(max));
}

function settingsBody(draft: SettingsDraft) {
  if (!ipv4(draft.address)) throw new Error('DNS listener address must be an IPv4 literal.');
  if (!integer(draft.port, 1, 65535)) throw new Error('DNS listener port must be an integer from 1 to 65535.');
  if (!draft.servers.length) throw new Error('Add at least one upstream server.');
  draft.servers.forEach((server, index) => {
    if (!ipv4(server.address)) throw new Error(`Upstream ${index + 1} requires an IPv4 literal.`);
    if (!integer(server.port, 1, 65535)) throw new Error(`Upstream ${index + 1} port must be an integer from 1 to 65535.`);
  });
  if (!integer(draft.timeout, 1, 4294967295)) throw new Error('Timeout must be an integer from 1 to 4294967295 milliseconds.');
  if (!integer(draft.capacity, 0)) throw new Error('Cache capacity must be a nonnegative integer, without fractions or exponent notation.');
  if (!integer(draft.minPositiveTtl, 0, 4294967295)) throw new Error('Minimum positive cache retention must be an integer from 0 to 4294967295 seconds.');
  for (const [label, value] of [['TCP maximum connections', draft.maxConnections], ['TCP idle timeout', draft.idleTimeout], ['TCP read timeout', draft.readTimeout], ['TCP write timeout', draft.writeTimeout]]) {
    if (!integer(value, 1, 4294967295)) throw new Error(`${label} must be an integer from 1 to 4294967295.`);
  }
  const dns = {
    listen: { address: draft.address, port: Number(draft.port) },
    tcp: { max_connections: Number(draft.maxConnections), idle_timeout_ms: Number(draft.idleTimeout), read_timeout_ms: Number(draft.readTimeout), write_timeout_ms: Number(draft.writeTimeout) },
  };
  const upstream = { servers: draft.servers.map((server) => ({ address: server.address, port: Number(server.port) })), timeout_ms: Number(draft.timeout) };
  return new RawJson(`{"dns":${JSON.stringify(dns)},"upstream":${JSON.stringify(upstream)},"cache":{"capacity":${draft.capacity},"min_positive_ttl_seconds":${draft.minPositiveTtl}},"logging":{"level":${JSON.stringify(draft.level)}}}`);
}

export function SettingsPage() {
  const api = useApi();
  const query = useQuery({ queryKey: ['/settings'], queryFn: ({ signal }) => api.read<Schema<'Settings'>>('/settings', signal) });
  return <Stack gap="xl"><PageHeading title="Settings" description="Replace runtime settings without changing rules, records, blocklists, or API and UI configuration." /><ErrorNotice error={query.error} />{query.isPending ? <Loader aria-label="Loading settings" /> : query.data ? <SettingsEditor initial={query.data} /> : <Button variant="default" onClick={() => void query.refetch()}>Retry loading settings</Button>}</Stack>;
}

function SettingsEditor({ initial }: { initial: Snapshot<Schema<'Settings'>> }) {
  const api = useApi();
  const writer = useWrite();
  const [base, setBase] = useState(initial);
  const [draft, setDraft] = useState(() => settingsDraft(initial));
  const [baseline, setBaseline] = useState(() => JSON.stringify(settingsDraft(initial)));
  const [review, setReview] = useState<Snapshot<Schema<'Settings'>> | null>(null);
  const [needsReview, setNeedsReview] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [reading, setReading] = useState(false);
  const [saved, setSaved] = useState(false);
  const [discard, setDiscard] = useState(false);
  const dirty = JSON.stringify(draft) !== baseline;
  const locked = writer.busy || reading;
  function update<K extends keyof SettingsDraft>(key: K, value: SettingsDraft[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
    setSaved(false);
  }
  async function refresh() {
    setReading(true); setError(null);
    try { setReview(await api.read<Schema<'Settings'>>('/settings')); } catch (failure) { setError(failure); } finally { setReading(false); }
  }
  async function save() {
    setError(null); setSaved(false);
    let body: RawJson;
    try { body = settingsBody(draft); } catch (failure) { setError(failure); return; }
    try {
      await writer.submit('/settings', 'PUT', body, base.etag);
      setBaseline(JSON.stringify(draft)); setSaved(true); setNeedsReview(true); setReview(null);
    } catch (failure) {
      setError(failure);
      setNeedsReview(true); setReview(null);
    }
  }
  return <Stack gap="lg">
    <DraftGuard dirty={dirty} />
    <Group justify="space-between"><Group gap="xs"><Text size="sm">Viewed revision <Code>{base.etag}</Code></Text>{dirty && <Badge color="orange" variant="light">Unsaved draft</Badge>}</Group><Button variant="default" loading={reading} disabled={writer.busy} onClick={() => void refresh()}>Refresh for review</Button></Group>
    <ErrorNotice error={error} />
    {saved && <Alert color="teal" title="Settings operation completed">Your submitted settings were saved and activated. Refresh and review active state before another write.</Alert>}
    {needsReview && !saved && <Alert color="orange" title={error instanceof ApiError && error.status === 412 ? 'Revision changed · draft preserved' : 'Inspect active state before retrying'}>Refresh for review, compare the current values, then explicitly choose whether to keep your draft. A failed operation can still have saved changes to disk.</Alert>}
    {review && <Alert color="blue" title="Review current settings"><RevisionReview key={review.etag + review.raw} raw={review.raw} etag={review.etag} busy={locked} onAccept={() => { setBase(review); setNeedsReview(false); setReview(null); setError(null); setSaved(false); }} /><Button mt="sm" variant="subtle" disabled={locked} onClick={() => setDiscard(true)}>Discard draft and load these settings…</Button></Alert>}
    <form onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <Stack gap="xl">
        <Fieldset legend="DNS listener" disabled={locked}>
          <SimpleGrid cols={{ base: 1, sm: 2 }}><TextInput label="IPv4 address" required value={draft.address} onChange={(event) => update('address', event.currentTarget.value)} description="Listener changes can cause a brief serving gap." /><TextInput label="Port" required inputMode="numeric" value={draft.port} onChange={(event) => update('port', event.currentTarget.value)} description="1–65535" /></SimpleGrid>
        </Fieldset>
        <Fieldset legend="DNS TCP limits" disabled={locked}>
          <Stack gap="md">
            <Text size="sm" c="dimmed">Changes apply to new connections without restarting the listener. All values must be integers from 1 to 4294967295.</Text>
            <SimpleGrid cols={{ base: 1, sm: 2 }}>
              <TextInput label="Maximum connections" required inputMode="numeric" value={draft.maxConnections} onChange={(event) => update('maxConnections', event.currentTarget.value)} />
              <TextInput label="Idle timeout (milliseconds)" required inputMode="numeric" value={draft.idleTimeout} onChange={(event) => update('idleTimeout', event.currentTarget.value)} />
              <TextInput label="Read timeout (milliseconds)" required inputMode="numeric" value={draft.readTimeout} onChange={(event) => update('readTimeout', event.currentTarget.value)} />
              <TextInput label="Write timeout (milliseconds)" required inputMode="numeric" value={draft.writeTimeout} onChange={(event) => update('writeTimeout', event.currentTarget.value)} />
            </SimpleGrid>
          </Stack>
        </Fieldset>
        <Fieldset legend="Upstream resolvers" disabled={locked}>
          <Stack gap="md">
            <Text size="sm" c="dimmed">Use one or more IPv4 upstreams. Changing servers clears the response cache; changing only the timeout preserves it.</Text>
            {draft.servers.map((server, index) => <Group key={index} align="flex-start" wrap="wrap"><TextInput style={{ flex: '1 1 220px' }} label={`Upstream ${index + 1} address`} required value={server.address} onChange={(event) => update('servers', draft.servers.map((item, position) => position === index ? { ...item, address: event.currentTarget.value } : item))} /><TextInput style={{ flex: '0 1 130px' }} label={`Upstream ${index + 1} port`} required inputMode="numeric" value={server.port} onChange={(event) => update('servers', draft.servers.map((item, position) => position === index ? { ...item, port: event.currentTarget.value } : item))} /><Button mt={25} variant="subtle" color="red" disabled={draft.servers.length === 1} aria-label={`Remove upstream ${index + 1}`} onClick={() => update('servers', draft.servers.filter((_, position) => position !== index))}>Remove</Button></Group>)}
            <Button variant="default" style={{ alignSelf: 'flex-start' }} onClick={() => update('servers', [...draft.servers, { address: '', port: '53' }])}>Add upstream</Button>
            <TextInput label="Timeout (milliseconds)" description="1–4294967295" required inputMode="numeric" value={draft.timeout} onChange={(event) => update('timeout', event.currentTarget.value)} maw={420} />
          </Stack>
        </Fieldset>
        <SimpleGrid cols={{ base: 1, sm: 2 }}>
          <Fieldset legend="Cache" disabled={locked}>
            <Stack gap="md">
              <TextInput label="Capacity (slots)" required inputMode="numeric" value={draft.capacity} onChange={(event) => update('capacity', event.currentTarget.value)} description="0 disables caching. Capacity changes replace the cache. The server enforces its platform integer limit." />
              <TextInput label="Minimum positive retention (seconds)" required inputMode="numeric" value={draft.minPositiveTtl} onChange={(event) => update('minPositiveTtl', event.currentTarget.value)} description="0–4294967295; default 0 respects upstream TTL. Longer internal reuse can serve stale destinations. Client TTLs still age to zero, never extended. Zero-TTL packets and negative replies are unchanged. Changing this value clears the cache." />
            </Stack>
          </Fieldset>
          <Fieldset legend="Logging" disabled={locked}><Select label="Log level" allowDeselect={false} data={[{ value: 'err', label: 'Error' }, { value: 'warn', label: 'Warning' }, { value: 'info', label: 'Info' }, { value: 'debug', label: 'Debug' }]} value={draft.level} onChange={(value) => { if (value) update('level', value as SettingsDraft['level']); }} /></Fieldset>
        </SimpleGrid>
        <Group><Button type="submit" loading={writer.busy} disabled={reading || needsReview || !dirty}>Save & activate settings</Button><Text size="sm" c="dimmed">All four sections are replaced together.</Text></Group>
      </Stack>
    </form>
    <Modal opened={discard} onClose={() => setDiscard(false)} title="Discard your settings draft?">
      <Stack><Text>Your unsaved settings will be replaced by the active settings shown in the review.</Text><Group justify="flex-end"><Button variant="default" onClick={() => setDiscard(false)}>Keep draft</Button><Button color="red" onClick={() => { if (review) { const current = settingsDraft(review); setDraft(current); setBaseline(JSON.stringify(current)); setBase(review); setNeedsReview(false); setReview(null); setError(null); setSaved(false); } setDiscard(false); }}>Discard and load</Button></Group></Stack>
    </Modal>
  </Stack>;
}

export function ConfigurationPage() {
  const api = useApi();
  const query = useQuery({ queryKey: ['/config'], queryFn: ({ signal }) => api.read<Schema<'Config'>>('/config', signal) });
  return <Stack gap="xl"><PageHeading title="Configuration" description="Inspect and replace the complete active document, or reload the operator-owned file." /><ErrorNotice error={query.error} />{query.isPending ? <Loader aria-label="Loading configuration" /> : query.data ? <ConfigurationEditor initial={query.data} /> : <Button variant="default" onClick={() => void query.refetch()}>Retry loading configuration</Button>}</Stack>;
}

function ConfigurationEditor({ initial }: { initial: Snapshot<Schema<'Config'>> }) {
  const api = useApi();
  const writer = useWrite();
  const [base, setBase] = useState(initial);
  const [draft, setDraft] = useState(() => formatJson(initial.raw));
  const [baseline, setBaseline] = useState(() => formatJson(initial.raw));
  const [validated, setValidated] = useState<string | null>(null);
  const [validating, setValidating] = useState(false);
  const [reading, setReading] = useState(false);
  const [review, setReview] = useState<Snapshot<Schema<'Config'>> | null>(null);
  const [needsReview, setNeedsReview] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const [completed, setCompleted] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<'replace' | 'reload' | 'discard' | null>(null);
  const dirty = draft !== baseline;
  const locked = writer.busy || validating || reading;
  async function validate() {
    setValidating(true); setError(null); setValidated(null);
    try {
      JSON.parse(draft);
      await api.request<{ valid: boolean }>('/config/validate', 'POST', new RawJson(draft));
      setValidated(draft);
    } catch (failure) { setError(failure); } finally { setValidating(false); }
  }
  async function refresh() {
    setReading(true); setError(null);
    try { setReview(await api.read<Schema<'Config'>>('/config')); } catch (failure) { setError(failure); } finally { setReading(false); }
  }
  async function apply(kind: 'replace' | 'reload') {
    setError(null); setCompleted(null);
    try {
      await writer.submit(kind === 'replace' ? '/config' : '/config/reload', kind === 'replace' ? 'PUT' : 'POST', kind === 'replace' ? new RawJson(draft) : undefined, base.etag);
      if (kind === 'replace') setBaseline(draft);
      setCompleted(kind === 'replace' ? 'Replacement saved and activated. Your editor text has been retained.' : 'The operator-owned file was reloaded and activated. Your editor draft has not been changed.');
      setNeedsReview(true); setReview(null); setValidated(null);
    } catch (failure) { setError(failure); setNeedsReview(true); setReview(null); }
    finally { setConfirmation(null); }
  }
  return <Stack gap="lg">
    <DraftGuard dirty={dirty} />
    <Alert color="blue" title="Active configuration, not raw disk contents">This document is the canonical running configuration. A replacement saves the entire document: omitted collections become empty. Only schema_version 2 is supported; non-null api and ui objects are required. Both enabled flags default to true, and UI enabled requires API enabled. Preserve both sections: API and UI settings, including the shared HTTP listener, require a service restart. Live changes are rejected before saving or publication.</Alert>
    <Group justify="space-between"><Group gap="xs"><Text size="sm">Viewed revision <Code>{base.etag}</Code></Text>{dirty && <Badge color="orange" variant="light">Unsaved draft</Badge>}</Group><Button variant="default" loading={reading} disabled={writer.busy || validating} onClick={() => void refresh()}>Refresh active document for review</Button></Group>
    <ErrorNotice error={error} />
    {completed && <Alert color="teal" title="Operation completed">{completed} Refresh and review active state before another write.</Alert>}
    {needsReview && !completed && <Alert color="orange" title={error instanceof ApiError && error.status === 412 ? 'Revision changed · draft preserved' : 'Review active state before retrying'}>Refresh the active document and compare it with your draft. Failure does not guarantee the saved file is unchanged. No write will be automatically retried.</Alert>}
    {review && <Alert color="blue" title="Review current active configuration"><RevisionReview key={review.etag + review.raw} raw={review.raw} etag={review.etag} busy={locked} onAccept={() => { setBase(review); setNeedsReview(false); setReview(null); setError(null); setCompleted(null); setValidated(null); }} /><Button mt="sm" variant="subtle" disabled={locked} onClick={() => setConfirmation('discard')}>Discard draft and load this document…</Button></Alert>}
    <JsonInput label="Complete configuration JSON" description="Strict JSON: no comments, duplicate or unknown fields, trailing commas, or fractional/exponent integer values. Formats on blur without rounding numbers or changing tokens." minRows={22} autosize maxRows={42} validationError="Invalid JSON syntax" formatOnBlur={false} spellCheck={false} autoCapitalize="off" autoCorrect="off" styles={{ input: { fontFamily: 'var(--mantine-font-family-monospace)', fontSize: 13, tabSize: 2 } }} value={draft} disabled={locked} onChange={(value) => { setDraft(value); setValidated(null); setCompleted(null); }} onBlur={() => { const formatted = formatJson(draft); if (formatted !== draft) { setDraft(formatted); setValidated(null); } }} />
    {validated === draft && <Alert color="teal" title="Configuration is valid">Validation checks syntax and configuration values only. It does not load sources, bind sockets, save the file, or prove activation will succeed.</Alert>}
    <Group><Button variant="default" loading={validating} disabled={writer.busy || reading || !draft.trim()} onClick={() => void validate()}>Validate JSON</Button><Button disabled={locked || needsReview || validated !== draft} onClick={() => setConfirmation('replace')}>Replace & activate…</Button></Group>
    <Divider />
    <section><Title order={2} size="h3" mb="xs">Reload from disk</Title><Text size="sm" mb="md">Activate the operator-owned configuration file, not this editor draft. Unchanged imported snapshots are retained; reload is not a blocklist refresh.</Text><Button variant="default" disabled={locked || needsReview} onClick={() => setConfirmation('reload')}>Reload configuration file…</Button></section>
    <Modal opened={confirmation !== null} onClose={() => { if (!writer.busy) setConfirmation(null); }} closeOnClickOutside={!writer.busy} closeOnEscape={!writer.busy} withCloseButton={!writer.busy} title={confirmation === 'replace' ? 'Replace the complete configuration?' : confirmation === 'reload' ? 'Reload the configuration file?' : 'Discard your configuration draft?'}>
      <Stack>
        <Text>{confirmation === 'replace' ? 'This saves and activates your complete JSON document. Omitted rules, records, and blocklists are removed. Listener changes may briefly interrupt DNS. A failed activation may still leave this candidate saved on disk.' : confirmation === 'reload' ? 'This activates the file currently on disk. It does not save your editor draft. Your draft will remain in the editor, and you must review the refreshed active configuration before another write.' : 'Your editor text will be replaced with the active document shown in the review. This cannot be undone.'}</Text>
        {confirmation !== 'discard' && <Text size="sm">Using viewed revision <Code>{base.etag}</Code>.</Text>}
        <Group justify="flex-end"><Button variant="default" disabled={writer.busy} onClick={() => setConfirmation(null)}>Cancel</Button><Button color={confirmation === 'reload' ? 'teal' : 'red'} loading={writer.busy} onClick={() => {
          if (confirmation === 'discard') { if (review) { const formatted = formatJson(review.raw); setBase(review); setDraft(formatted); setBaseline(formatted); setNeedsReview(false); setReview(null); setError(null); setValidated(null); setCompleted(null); } setConfirmation(null); }
          else if (confirmation) void apply(confirmation);
        }}>{confirmation === 'replace' ? 'Replace & activate' : confirmation === 'reload' ? 'Reload from disk' : 'Discard and load'}</Button></Group>
      </Stack>
    </Modal>
  </Stack>;
}

const policyReasons: Record<Schema<'Policy'>['reason'], string> = {
  explicit_block: 'An explicit block matches this exact name. Explicit blocks take precedence over allows and local records.',
  explicit_allow: 'An explicit allow bypasses imported blocklists. Matching local records can still answer; otherwise normal cache/upstream handling applies.',
  local_record: 'A local record set matches this exact name and IN question type.',
  imported_blocklist: 'This exact name appears in an enabled imported blocklist, with no higher-priority policy allowing it.',
  default_forward: 'No blocking or local-answer policy applies. Normal cache/upstream handling would follow.',
};

export function PolicyPage() {
  const api = useApi();
  const [name, setName] = useState('');
  const [type, setType] = useState('A');
  const [numeric, setNumeric] = useState('');
  const [path, setPath] = useState<string | null>(null);
  const [inputError, setInputError] = useState<unknown>(null);
  const query = useQuery({ queryKey: [path ?? '/policy/check'], queryFn: ({ signal }) => api.read<Schema<'Policy'>>(path!, signal), enabled: path !== null, retry: false });
  const result = query.data?.data;
  function check() {
    setInputError(null);
    if (!name.trim()) { setInputError(new Error('Enter an exact DNS name to check.')); return; }
    if (type === 'numeric' && !integer(numeric, 0, 65535)) { setInputError(new Error('DNS type must be an integer from 0 to 65535.')); return; }
    const next = `/policy/check?${new URLSearchParams({ name: name.trim(), type: type === 'numeric' ? numeric : type })}`;
    if (next === path) void query.refetch();
    else setPath(next);
  }
  return <Stack gap="xl">
    <PageHeading title="Policy check" description="Inspect the decision for one exact DNS name and IN question type. No DNS lookup is performed." />
    <form onSubmit={(event) => { event.preventDefault(); check(); }}><Stack><SimpleGrid cols={{ base: 1, sm: 2 }}><TextInput label="DNS name" description="Exact normalized ASCII name; punycode is supported. No wildcards." placeholder="home.example.test" required value={name} onChange={(event) => setName(event.currentTarget.value)} /><Select label="Question type" allowDeselect={false} data={[{ value: 'A', label: 'A · IPv4' }, { value: 'AAAA', label: 'AAAA · IPv6' }, { value: 'numeric', label: 'Numeric DNS type' }]} value={type} onChange={(value) => { if (value) setType(value); }} /></SimpleGrid>{type === 'numeric' && <TextInput label="Numeric DNS type" description="0–65535; assumes class IN" inputMode="numeric" required value={numeric} onChange={(event) => setNumeric(event.currentTarget.value)} maw={320} />}<Button type="submit" loading={query.isFetching} style={{ alignSelf: 'flex-start' }}>Check policy</Button></Stack></form>
    <ErrorNotice error={inputError || query.error} />
    {!path && <Text c="dimmed" size="sm">Enter a name to see which rule takes precedence. This tool does not resolve addresses or test upstream reachability.</Text>}
    {result && <section aria-labelledby="policy-result-heading" aria-live="polite">
      <Group justify="space-between" mb="md"><Title id="policy-result-heading" order={2} size="h3">Decision for {result.name}</Title><Badge color={result.decision === 'block' ? 'red' : result.decision === 'local' ? 'teal' : 'blue'} variant="light">{result.decision === 'block' ? 'Block' : result.decision === 'local' ? 'Local answer' : 'Forward policy'}</Badge></Group>
      <Text mb="xs">{policyReasons[result.reason]}</Text><Text size="sm" c="dimmed" mb="md">Type {result.type} · class IN · exact-name matching · revision {query.data?.etag}</Text>
      <Table><Table.Tbody>
        <Table.Tr><Table.Th>Reason</Table.Th><Table.Td><Code>{result.reason}</Code></Table.Td></Table.Tr>
        <Table.Tr><Table.Th>Explicit block</Table.Th><Table.Td>{result.explicit_block ? 'Match' : 'No match'}</Table.Td></Table.Tr>
        <Table.Tr><Table.Th>Explicit allow</Table.Th><Table.Td>{result.explicit_allow ? 'Match' : 'No match'}</Table.Td></Table.Tr>
        <Table.Tr><Table.Th>Imported blocklist</Table.Th><Table.Td>{result.imported_block ? 'Match' : 'No match'}</Table.Td></Table.Tr>
        <Table.Tr><Table.Th>Local record for this type</Table.Th><Table.Td>{result.local_record ? 'Match' : 'No match'}</Table.Td></Table.Tr>
      </Table.Tbody></Table>
      <Alert color="blue" title="Policy only · no upstream query" mt="md">A forward decision does not resolve the name or guarantee an upstream request: a real query may be answered by cache. Local and blocking answers are not tested by this check.</Alert>
    </section>}
  </Stack>;
}
