import { createContext, useContext, useMemo, useRef, useState, useEffect, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import type { components } from './generated/api';
export type Schema<K extends keyof components['schemas']> = components['schemas'][K];
export class RawJson { constructor(public text: string) {} }
export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
export const apiNotFoundMessage = 'The UI could not reach the VoidDNS API. The embedded UI and API share one listener; the service may have stopped or the connection may be interrupted. Check the VoidDNS service and network connection, then retry. If you were saving changes, inspect current state before submitting again.';
export async function requestApi<T>(path: string, apiKey = '', method = 'GET', body?: unknown, etag?: string, signal?: AbortSignal): Promise<Reply<T>> {
  const headers: Record<string, string> = {};
  if (apiKey) headers['X-API-Key'] = apiKey;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (etag) headers['If-Match'] = etag;
  const requestSignal = signal ? AbortSignal.any([signal, AbortSignal.timeout(10000)]) : AbortSignal.timeout(10000);
  let response: Response;
  let raw: string;
  try {
    response = await fetch(`/api/v1${path}`, { method, headers, body: body === undefined ? undefined : body instanceof RawJson ? body.text : JSON.stringify(body), signal: requestSignal, cache: 'no-store', credentials: 'omit', redirect: 'error' });
    raw = await response.text();
  } catch (cause) {
    if (signal?.aborted) throw cause;
    throw new ApiError(0, 'ApiNotFound', apiNotFoundMessage);
  }
  if (response.status === 401) throw new ApiError(401, 'Unauthorized', 'Invalid API key. Enter a valid administrator API key and try again.');
  if ([502, 503, 504].includes(response.status)) throw new ApiError(response.status, 'ApiNotFound', apiNotFoundMessage);
  let data: unknown;
  try { data = JSON.parse(raw); } catch { throw new ApiError(response.status, 'ApiNotFound', apiNotFoundMessage); }
  if (!data || typeof data !== 'object' || Array.isArray(data)) throw new ApiError(response.status, 'ApiNotFound', apiNotFoundMessage);
  if (!response.ok) {
    const error = 'error' in data ? data.error : null;
    const code = error && typeof error === 'object' && 'code' in error && typeof error.code === 'string' ? error.code : 'RequestFailed';
    const message = error && typeof error === 'object' && 'message' in error && typeof error.message === 'string' ? error.message : `Request failed (${response.status})`;
    if (code === 'RequestFailed' || (response.status === 404 && path === '/status')) throw new ApiError(response.status, 'ApiNotFound', apiNotFoundMessage);
    throw new ApiError(response.status, code, message);
  }
  if (path === '/status' && (!('dns' in data) || !data.dns || typeof data.dns !== 'object' || !('ready' in data.dns) || typeof data.dns.ready !== 'boolean')) throw new ApiError(response.status, 'ApiNotFound', apiNotFoundMessage);
  return { data: data as T, etag: response.headers.get('ETag') ?? '', raw };
}
type Reply<T> = { data: T; etag: string; raw: string };
type Api = { read<T>(path: string, signal?: AbortSignal): Promise<Reply<T>>; request<T>(path: string, method: string, body?: unknown, etag?: string): Promise<Reply<T>> };
const ApiContext = createContext<Api | null>(null);
type WriteState = { submit(path: string, method: string, body: unknown, etag: string): Promise<void>; busy: boolean; operation: Schema<'Operation'> | null; error: unknown; resume(): void };
const WriteContext = createContext<WriteState | null>(null);
export function useApi() { const api = useContext(ApiContext); if (!api) throw new Error('Missing API session'); return api; }
export function useWrite() { const value = useContext(WriteContext); if (!value) throw new Error('Missing write session'); return value; }
export function ApiProvider({ apiKey, children, onUnauthorized, onUnavailable }: { apiKey: string; children: ReactNode; onUnauthorized(): void; onUnavailable(): void }) {
  const client = useQueryClient();
  const api = useMemo<Api>(() => {
    async function send<T>(path: string, method: string, body?: unknown, etag?: string, signal?: AbortSignal): Promise<Reply<T>> {
      try {
        return await requestApi<T>(path, apiKey, method, body, etag, signal);
      } catch (cause) {
        if (cause instanceof ApiError) {
          if (cause.status === 401) onUnauthorized();
          if (cause.code === 'ApiNotFound') onUnavailable();
        }
        throw cause;
      }
    }
    return { read: (path, signal) => send(path, 'GET', undefined, undefined, signal), request: (path, method, body, etag) => send(path, method, body, etag) };
  }, [apiKey, onUnauthorized, onUnavailable]);
  const [busy, setBusy] = useState(false);
  const locked = useRef(false);
  const alive = useRef(true);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const [operation, setOperation] = useState<Schema<'Operation'> | null>(null);
  const [error, setError] = useState<unknown>(null);
  async function follow(initial: Schema<'Operation'>) {
    let current = initial;
    while (current.status === 'running' || current.status === 'queued') {
      const { promise, resolve } = Promise.withResolvers<void>();
      setTimeout(resolve, 700);
      await promise;
      if (!alive.current) throw new Error('Session closed; accepted operations continue on the server.');
      current = (await api.read<Schema<'Operation'>>(`/operations/${current.id}`)).data;
      setOperation(current);
    }
    await client.invalidateQueries();
    if (current.status === 'failed') throw new Error(`Operation ${current.id} failed: ${current.error ?? 'unknown error'}. Inspect saved and active state before retrying.`);
  }
  async function submit(path: string, method: string, body: unknown, etag: string) {
    if (locked.current || operation?.status === 'running' || operation?.status === 'queued') throw new Error('An operation is still pending. Resume polling before another write; if the server restarted, sign out and reconnect.');
    if (!etag) throw new Error('Read current state before making changes.');
    locked.current = true; setBusy(true); setError(null); setOperation(null);
    try {
      const response = await api.request<Schema<'Accepted'> | {cleared: boolean}>(path, method, body, etag);
      if ('operation' in response.data) { setOperation(response.data.operation); await follow(response.data.operation); }
      else await client.invalidateQueries();
    } catch (cause) { setError(cause); throw cause; }
    finally { locked.current = false; setBusy(false); }
  }
  function resume() {
    if (!operation || locked.current) return;
    locked.current = true; setBusy(true); setError(null);
    void follow(operation).catch(setError).finally(() => { locked.current = false; setBusy(false); });
  }
  return <ApiContext.Provider value={api}><WriteContext.Provider value={{ submit, busy, operation, error, resume }}>{children}</WriteContext.Provider></ApiContext.Provider>;
}
