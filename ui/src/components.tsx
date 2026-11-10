import { Alert, Button, Group, Stack, Text, Title } from '@mantine/core';
import { ApiError, useWrite } from './api';
export function ErrorNotice({error}: {error: unknown}) {
  if (!error) return null;
  const message = error instanceof Error ? error.message : 'An unexpected error occurred.';
  return <Alert color="red" title="Request needs attention" role="alert"><Text size="sm">{message}</Text>{error instanceof ApiError && error.status === 412 ? <Text size="sm">The server changed since you loaded this data. Keep your draft, review current state, then submit again explicitly.</Text> : null}</Alert>;
}
export function PageHeading({title, description}: {title: string; description?: string}) { return <Stack gap={6} mb="lg"><Title order={1} size="h2">{title}</Title>{description ? <Text c="dimmed" maw={800}>{description}</Text> : null}</Stack>; }
export function OperationFeedback() {
  const {operation, error, busy, resume} = useWrite();
  if (!operation && !error) return null;
  return <Stack mb="lg" gap="xs"><ErrorNotice error={error} />{operation ? <Alert color={operation.status === 'failed' ? 'red' : operation.status === 'succeeded' ? 'teal' : 'blue'} title={`Operation ${operation.id} · ${operation.status}`} role="status">
    {operation.result ? <><Text size="sm">Saved: {operation.result.saved ? 'yes' : 'no'} · Active: {operation.result.active ? 'yes' : 'no'} · Durability: {operation.result.durability}</Text>{operation.result.saved && !operation.result.active ? <Text fw={600}>The file was saved, but this change is not active. Do not assume runtime and disk agree.</Text> : null}{operation.result.resource_id ? <Text size="sm">Resource: {operation.result.resource_id}</Text> : null}</> : <Text size="sm">Acceptance is not completion. An accepted operation continues even if you leave this page.</Text>}
    {!busy && (operation.status === 'running' || operation.status === 'queued') ? <Group mt="sm"><Button size="xs" onClick={resume}>Resume operation polling</Button></Group> : null}
  </Alert> : null}</Stack>;
}
