# VoidDNS management API

Developer and AI-agent reference for the implemented single-server API.
All paths in this document are relative to **`/api/v1`**; the default enabled
listener is `http://127.0.0.1:8080`.

- Machine-readable contract: [`src/api/openapi.json`](src/api/openapi.json), also
  served by authenticated `GET /openapi.json`.
- Startup and deployment: [README](README.md#management-api).
- Implementation: [`src/api/server.zig`](src/api/server.zig) (HTTP/authentication),
  [`src/api/management.zig`](src/api/management.zig) (operations and persistence),
  [`src/config/document.zig`](src/config/document.zig) (configuration types).

## Client and agent rules

1. Authenticate every request. Never log, commit, or embed the administrator key
   in public frontend code or agent transcripts.
2. Read current state before editing. Send its quoted global `ETag` as `If-Match`.
   POST creation also requires this precondition.
3. Treat PUT as replacement, not a patch. Preserve fields and resources you do
   not intend to change; prefer resource endpoints over whole-config writes.
4. A `202` response is acceptance, **not success**. Poll the operation until it
   completes; inspect both its status and result.
5. After a conflict or ambiguous network failure, inspect state before retrying.
   Do not blindly resubmit a write: it might already have saved or completed.
6. Revisions, cursors, and operation IDs are process-local. Discard them after a
   restart; do not use them as durable identifiers or idempotency keys.
7. Do not infer wildcard rules, recursive resolution, peer APIs, PATCH support,
   or undocumented endpoints from this document.

## Enablement and authentication

Schema version 2 requires non-null `api` and `ui` objects. Both `enabled`
fields default to `true`; `api.key_file` is required when the API is enabled.
Merge these sections into the existing configuration (not a standalone document):

```json
{
  "api": {
    "enabled": true,
    "listen": {"address": "127.0.0.1", "port": 8080},
    "key_file": "api.key",
    "allow_private_sources": false
  },
  "ui": {"enabled": true}
}
```

The UI is embedded in the executable and publicly served on the same listener;
all `/api/v1` requests remain authenticated. With API/UI enabled respectively:
`true/true` serves both, `true/false` serves API only (frontend `404`),
`false/false` serves DNS only with no HTTP listener or key loading, and
`false/true` is invalid. Missing assets and unknown frontend routes return `404`;
direct navigation supports `/`, `/domains`, `/records`, `/blocklists`, `/policy`,
`/settings`, and `/configuration`.

Schema 1 is unsupported; migrate to `schema_version: 2` and explicitly add both
objects. There is no legacy compatibility mode or implicit disabled API.

Generate a strong random key, for example 32 random bytes represented by 64
hexadecimal characters, without a trailing newline. The key is the file's exact
contents: no whitespace, LF, or CRLF trimming is performed. POSIX group/other
permission bits must be zero (use mode `0600`). `key_file` and optional `file_root` resolve
relative to the configuration directory. Do not overwrite an existing key merely
to run an example.

Send exactly one `X-API-Key` header containing the case-sensitive key, without a
Bearer prefix. Missing, duplicate, or incorrect keys return `401`. Every key has
administrator privileges, including access to the OpenAPI endpoint.

API/UI settings, the shared HTTP listener, and key rotation require restart.
Live updates changing API/UI settings are rejected before save or publication.
There is no built-in TLS or CORS: use HTTPS termination
and network controls for remote access. Browser clients need a suitable
same-origin deployment, not an administrator key in a public bundle.

## HTTP conventions

- Send JSON bodies with `Content-Type: application/json`.
- Resource bodies are limited to **64 KiB**; `/config` and `/config/validate`
  permit **1 MiB**. The persisted configuration is also limited to 1 MiB.
- Parsing is strict: unknown/duplicate fields, wrong types, and invalid values
  are rejected. Integer fields require unquoted integer tokens, not fractions
  or exponent notation. No JSON comments or trailing commas.
- Percent-encode resource IDs as individual path segments and encode query
  values. For example, `block:example.test` becomes `block%3Aexample.test`.
- Management reads expose the global revision through a quoted `ETag`, such as
  `"7"`. `/openapi.json` serves the static contract and has no revision ETag.
- Application responses are JSON. HTTP-library framing/parser errors can be
  plaintext. Rejected unread bodies close the connection; a transmitting client
  may observe a reset instead of the full error response.

## Endpoint reference

All endpoints require `X-API-Key`. Every state-changing request requires
`If-Match`; `POST /config/validate` is read-only and does not require it.
`Accepted` below means the asynchronous response described under Operations.
Action and DELETE requests need no body unless a body is explicitly listed.

| Method | Path | Request / behavior | Success |
| --- | --- | --- | --- |
| GET | `/status` | Listener and management status | `200` Status |
| GET | `/settings` | Active runtime settings | `200` Settings |
| PUT | `/settings` | Replace all four Settings sections | `202` Accepted |
| GET | `/config` | Canonical active configuration, not raw disk contents | `200` Config |
| PUT | `/config` | Replace, save, and activate complete Config | `202` Accepted |
| POST | `/config/validate` | Validate Config without source loads or socket binding | `200` `{"valid":true}` |
| POST | `/config/reload` | Activate the operator-owned configuration file | `202` Accepted |
| GET | `/domains` | Paginated explicit rules; optional `action`, `domain` filters | `200` Page of Domain |
| POST | `/domains` | Create DomainInput | `202` Accepted |
| GET | `/domains/{id}` | Read explicit rule | `200` Domain |
| PUT | `/domains/{id}` | Replace with DomainInput | `202` Accepted |
| DELETE | `/domains/{id}` | Delete explicit rule | `202` Accepted |
| GET | `/records` | Paginated local record sets | `200` Page of Record |
| POST | `/records` | Create RecordInput | `202` Accepted |
| GET | `/records/{id}` | Read local record set | `200` Record |
| PUT | `/records/{id}` | Replace with RecordInput | `202` Accepted |
| DELETE | `/records/{id}` | Delete local record set | `202` Accepted |
| GET | `/blocklists` | Paginated source definitions, not imported names | `200` Page of Source |
| POST | `/blocklists` | Create Source | `202` Accepted |
| GET | `/blocklists/{id}` | Read source definition | `200` Source |
| PUT | `/blocklists/{id}` | Replace Source; body ID must match path ID | `202` Accepted |
| DELETE | `/blocklists/{id}` | Remove source and its imported membership | `202` Accepted |
| POST | `/blocklists/{id}/refresh` | Load one source using its active definition | `202` Accepted |
| POST | `/blocklists/refresh` | Atomically refresh all enabled sources | `202` Accepted |
| GET | `/blocklists/refresh` | Read source whose ID is literally `refresh` | `200` Source |
| PUT | `/blocklists/refresh` | Replace source whose ID is literally `refresh` | `202` Accepted |
| DELETE | `/blocklists/refresh` | Delete source whose ID is literally `refresh` | `202` Accepted |
| GET | `/operations/{id}` | Poll decimal operation ID | `200` Operation |
| GET | `/policy/check` | Required `name`; optional `type` (default `A`) | `200` Policy |
| GET | `/cache` | Capacity and occupied slots | `200` Cache |
| DELETE | `/cache/entries` | Clear all upstream response-cache entries | `200` `{"cleared":true,"revision":8}` |
| GET | `/openapi.json` | Embedded OpenAPI 3.1 document | `200` OpenAPI |

## Resource bodies and identities

### Explicit domains

DomainInput, used for both POST and PUT:

```json
{"domain":"example.test","action":"block"}
```

Both fields are required. `action` is `allow` or `block`. Names are normalized
ASCII, case-insensitive, with an optional trailing dot. Matching is exact, never
suffix or wildcard matching. Punycode and underscore labels are supported;
IP-literal names and non-ASCII input are rejected.

Domain responses add `id`, for example `block:example.test`. Do not send `id`
in a DomainInput. Identity is the normalized action/name pair; allow and block
may coexist for the same name, but explicit block wins. PUT may change identity;
use the completed operation's `resource_id` for the resulting ID. Duplicate
identities return `409`.

### Local records

RecordInput, used for both POST and PUT:

```json
{"name":"home.test","type":"A","ttl":60,"addresses":["192.0.2.10","192.0.2.11"]}
```

| Field | Contract |
| --- | --- |
| `name` | Required; same exact-name normalization as domains |
| `type` | Required; `A` or `AAAA` only |
| `addresses` | Required; 1–16 matching-family IP literals |
| `ttl` | Optional, default 60; integer 0–4294967295 |

Binary-equivalent addresses are deduplicated in first-occurrence order. Address
order controls answer order. Record responses add `id`, such as `A:home.test`;
do not send it in RecordInput. Identity is normalized name/type; PUT may change
it. Duplicate identities return `409`.

Local answers apply only to matching IN A/AAAA questions. Missing record types
continue through normal policy/cache/upstream handling. Local and generated
blocking answers are not cached. Deleting a local record can expose an unexpired
upstream cache answer. A complete local RRset is returned, or a question-only
truncated response if the UDP limit cannot fit it.

### Blocklist sources

Source request example (a disabled definition; it does not fetch this URL):

```json
{
  "id":"example-list",
  "name":"Example list",
  "enabled":false,
  "source":{"kind":"url","value":"https://example.com/domains.txt"},
  "format":"domains"
}
```

| Field | Contract |
| --- | --- |
| `id` | Required, unique and immutable; 1–128 ASCII alphanumeric or `._-` characters |
| `name` | Optional display name; 1–256 printable ASCII characters when provided |
| `enabled` | Optional, default true; disabled definitions are still validated |
| `source.kind` | Required; `url` or `file` |
| `source.value` | Required URL or file path |
| `format` | Required; URLs accept `domains` only; files accept `domains` or `hosts` |
| `api_managed` | Server-enforced persistent provenance; omit in normal client requests |

New or content-modified API sources become `api_managed: true`. Clients cannot
clear this marker to bypass restrictions. Unchanged operator-provided locations
retain their trust; metadata-only edits do not refetch or convert those paths.

API-managed files require `api.file_root` and paths relative to that root.
Absolute paths, traversal, symlinks, and non-regular files are rejected.
API-managed HTTP/HTTPS imports reject redirects and pin validated destination
addresses while retaining TLS hostname verification. Private-network access is
denied unless explicitly enabled with `api.allow_private_sources` (default false).
Do not enable it merely to bypass a failed import.

Imports have a 32 MiB decompressed limit and a 30-second whole-load deadline.
URL lists must contain single-domain rows, blank lines, or `#` comments (inline
comments accepted). Invalid rows fail the whole import. Local hosts files accept
an IPv4/IPv6 address followed by aliases, ignoring customary localhost aliases.
CRLF is accepted. No automatic hosts/Adblock detection or wildcard interpretation.

Reload retains unchanged imported snapshots; it is **not refresh**. Refresh uses
active definitions, not unapplied disk edits. Disabled-source refresh is a no-op;
unknown source IDs return `404`. Refresh-all is all-or-nothing. Removing one
source preserves domains still supplied by another source. Imported snapshots
are RAM-only and rebuild on restart.

### Settings and full configuration

Settings contains all four required sections:

```json
{
  "dns":{"listen":{"address":"127.0.0.1","port":5353}},
  "upstream":{"servers":[{"address":"1.1.1.1","port":53}],"timeout_ms":3000},
  "cache":{"capacity":4096,"min_positive_ttl_seconds":0},
  "logging":{"level":"info"}
}
```

The optional `dns.tcp` object contains positive-u32 `max_connections` (64),
`idle_timeout_ms` (10000), `read_timeout_ms` (5000), and `write_timeout_ms` (5000).
GET returns explicit defaults; PUT/settings and complete configuration saves
persist them. Live changes affect new TCP connections without rebinding;
existing connections retain their admission-time settings.

PUT `/settings` replaces these sections while retaining records, explicit rules,
source definitions, and API/UI settings. Ports are 1–65535; transport addresses are
IPv4 literals; upstream servers must be nonempty. Timeout is a positive u32.
Cache capacity is a nonnegative integer fitting `usize`, counts slots rather than
bytes, and zero disables caching. Log levels: `err`, `warn`, `info`, `debug`.
Nested omitted settings use their configuration defaults; this is not a merge.

`cache.min_positive_ttl_seconds` is an optional u32 (0–4294967295), default `0`.
It raises internal reuse of cacheable positive upstream responses to at least the
configured duration, without renewing on hits or extending client TTLs. Client
TTLs age from their original values and saturate at zero. Zero-TTL packets remain
non-cacheable; NXDOMAIN/NODATA lifetimes are unchanged. Larger values reduce
upstream requests but can serve stale destinations and delay failover. Changing
the value clears existing cached responses without restarting the DNS listener.
GET `/settings` and `/config` return it; PUT on either endpoint persists and
activates it through the usual revision/operation flow. The UI exposes it under
Settings → Cache as “Minimum positive retention (seconds)”.

Config uses schema version 2 and requires `schema_version`, non-null `api` and
`ui` objects, and `upstream.servers`. It contains the Settings sections plus optional
`records`, `blocks: {domains, lists}`, and `allows: {domains}`. See the
[configuration reference](README.md#startup-configuration) and
[complete example](examples/voiddns.json) for defaults and startup usage.

GET `/config` returns the canonical **active** document. PUT replaces the whole
configuration; omitted optional collections become empty. Preserve the existing
API/UI settings because changing them requires restart and is rejected before
saving or publishing. Validation alone does not prove that source downloads,
file access, persistence, or activation will succeed.

Rule/record/source changes preserve the DNS listener and cache. Upstream server
changes clear cache; timeout-only changes preserve it. Capacity changes replace
the cache. Listener changes require rebind and may cause a serving gap.

## Pagination

Collection GETs return `items`, `next_cursor` (string or null), and `revision`.
IDs sort lexicographically. `limit` accepts 1–100, default 50. Send the previous
`next_cursor` as URL-encoded `after`; treat it as opaque. Stop when it is null.
Keep filters unchanged between pages. `/domains` additionally accepts
`action=allow|block` and an exact normalized `domain` filter.

A revision change invalidates cursors (`409 StaleCursor`); restart the listing
rather than combining pages from different revisions. Collections enumerate
explicit resources, not all names contained in imported lists.

## Revisions, operations, and persistence

Use the exact quoted global revision, for example `If-Match: "7"`. Wildcards,
weak validators, and unquoted numbers do not match. Missing preconditions return
`428`; nonmatching values return `412`. Only one writer runs at a time; another
valid-revision mutation returns `409 OperationInProgress`.

Asynchronous acceptance example:

```json
{"operation":{"id":1,"status":"running","result":null,"error":null},"revision":7}
```

Poll `GET /operations/1`. Unlike acceptance, polling returns the Operation object
directly, not an `operation` wrapper. Example completed persistent creation:

```json
{
  "id":1,
  "status":"succeeded",
  "result":{
    "saved":true,
    "active":true,
    "durability":"durable",
    "revision":8,
    "resource_id":"block:example.test"
  },
  "error":null
}
```

| Field | Meaning |
| --- | --- |
| `status` | Implementation emits `running`, `succeeded`, or `failed`; clients may also encounter schema-defined `queued` |
| `result` | Null while running; completion result otherwise |
| `result.saved` | This operation saved the configuration file; not a general disk/runtime agreement flag |
| `result.active` | The operation successfully applied to runtime |
| `result.durability` | `unchanged` (no save), `durable`, or `uncertain` |
| `result.revision` | Global revision after completion |
| `result.resource_id` | Resulting resource identity, or null when not applicable |
| `error` | Error-name string on failure, otherwise null |

Reload/refresh can succeed with `saved: false`, `active: true`, and
`durability: "unchanged"`. Every completed operation, including failures, advances
the revision. Cache clearing is synchronous and advances it immediately.
Request rejection before acceptance is not a completed operation.

The last 64 completed operations are retained in RAM; missing/evicted IDs return
`404`. IDs and revisions reset on restart. Read requests and operation polling
remain available while source fetching/parsing runs in the background.

Persistent edits build from active configuration, save atomically through the
operator-owned `--config` file, then prepare and publish runtime changes. External
file editors must coordinate to avoid being overwritten. No second database is
used for API persistence.

**Failed does not mean unchanged on disk.** If source import or activation fails
after saving, the old runtime remains active but the candidate remains saved:
`result.saved: true`, `result.active: false`. Directory-sync failure reports
`durability: "uncertain"` and does not activate the candidate. Inspect the failure
and `/status`; use GET `/config` if you need the active document, then explicitly
PUT it back with a fresh revision only if restoring disk to active state is the
intended recovery. Never automatically overwrite the saved candidate.

## Read-only diagnostics

### Status

Status fields: `dns.ready` (boolean), `dns.generation` (worker generation),
`dns.listen` (address string), `revision`, `operation_id` (current ID or null),
and `saved_matches_active` (boolean or null).

Readiness means both UDP and TCP listener readiness, not upstream health. Saved/active agreement
is last known agreement from this process; it is null during an operation and
does not detect external file edits.

### Policy

`GET /policy/check?name=home.test&type=A` assumes class IN. `type` accepts `A`,
`AAAA`, or a numeric DNS type in 0–65535; it defaults to `A`.

Response fields: normalized `name`, numeric `type`, `decision` (`block`, `local`,
`forward`), `reason`, `exact: true`, booleans `explicit_block`, `explicit_allow`,
`imported_block`, `local_record`, and `upstream_queried: false`.
Reasons are `explicit_block`, `explicit_allow`, `local_record`,
`imported_blocklist`, and `default_forward`.

Explicit block wins. Explicit allow bypasses imported blocks but still permits
a matching local answer. A matching local answer also precedes imported blocks;
otherwise traffic proceeds to cache/upstream. A `forward` policy decision does
not perform a lookup or promise an upstream request rather than a cache hit.
Blocking generates A `0.0.0.0` or AAAA `::` with TTL zero; other types/classes
receive NOERROR/NODATA without SOA.

### Cache

GET `/cache` returns `capacity` and `occupied_slots`. Occupied slots may include
expired entries not yet reclaimed; these are not hit/miss statistics. DELETE
`/cache/entries` clears all cached upstream responses, not policy or local records.

## Errors and recovery

Application error shape:

```json
{"error":{"code":"RevisionMismatch","message":"RevisionMismatch"}}
```

Codes can be transport-style lowercase names, management error names, or
validation diagnostics; do not assume a single naming convention or a closed
error enum. Operation failures instead use the Operation `error` string.

| HTTP status | Meaning / client action |
| --- | --- |
| `400` | Invalid JSON, fields, values, encoding, duplicate parameters, or immutable source ID; correct request |
| `401` | Missing, duplicate, or incorrect key; fix authentication, never log the key |
| `404` | Unknown route/resource or missing/evicted operation; inspect current state |
| `405` | Unsupported method; use the endpoint table |
| `408` | Request timeout; inspect state before retrying a write |
| `409` | Busy writer, duplicate identity, stale cursor, or API/UI restart required; handle the specific cause |
| `412` | Revision mismatch; reread state and reconsider the intended change |
| `413` | Body exceeds limit; reduce request size |
| `428` | Missing `If-Match`; read current revision |
| `431` | Too many request headers; reduce headers |
| `500` | Internal failure; inspect state before retrying |
| `503` | Management unavailable or job launch failed; inspect availability and state |

## curl workflow

Requires Bash, curl with `--fail-with-body`, and jq. The API must already be
running. Set `KEY_FILE` to its existing restricted key file. This example creates
an explicit block for `blocked.test`; run only when that change is intended.
It uses a protected temporary header file rather than placing the key in curl's
process arguments. Do not enable shell tracing.

```bash
set -euo pipefail
API=http://127.0.0.1:8080/api/v1
KEY_FILE=/path/to/api.key
umask 077
AUTH=$(mktemp)
trap 'rm -f "$AUTH"' EXIT
printf 'X-API-Key: %s\n' "$(cat "$KEY_FILE")" > "$AUTH"

REV=$(curl --fail-with-body -sS -H @"$AUTH" "$API/status" | jq -er '.revision')
ACCEPTED=$(curl --fail-with-body -sS -H @"$AUTH" \
  -H "If-Match: \"$REV\"" -H 'Content-Type: application/json' \
  --data '{"domain":"blocked.test","action":"block"}' "$API/domains")
OP=$(jq -er '.operation.id' <<< "$ACCEPTED")

# Bound client waiting; a timeout here does not cancel the server operation.
for ((attempt=0; attempt<120; attempt++)); do
  RESULT=$(curl --fail-with-body -sS -H @"$AUTH" "$API/operations/$OP")
  case $(jq -er '.status' <<< "$RESULT") in
    succeeded) printf '%s\n' "$RESULT"; exit 0 ;;
    failed) printf '%s\n' "$RESULT" >&2; exit 1 ;;
    running|queued) sleep 1 ;;
    *) printf 'Unexpected operation status\n' >&2; exit 1 ;;
  esac
done
printf 'Still pending; inspect operation %s before another write\n' "$OP" >&2
exit 1
```

## Scope and contract maintenance

Not implemented: imported allowlists, wildcard/suffix matching, diagnostic DNS resolution, peer synchronization endpoints, key
management endpoints, or automatic source-refresh scheduling.
DNS caches and imported contents remain RAM-only.

When changing the API, update this reference, the embedded OpenAPI contract, and
relevant README guidance together. Check routing, validation, serialized response
shapes, and persistence behavior; do not document proposed features as available.

Known OpenAPI discrepancies in the current repository: `ApiSettings` advertises
`allow_private_sources` default true, but the implementation defaults to false;
`Operation` includes `queued`, while the implementation emits `running` upon
acceptance; generic path-ID descriptions say “source ID” even for domains,
records, and operations. Follow the identities and actual defaults documented
above rather than inferring runtime behavior from those schema annotations.

## Client telemetry and metrics

Client history is stored in a separate SQLite database, selected with
--database or defaulting to $HOME/.config/voiddns/voiddns.sqlite3. Configuration
continues to use the operator JSON file. Telemetry is asynchronous and may lose
events on overload or storage failure; GET /metrics/health exposes process-local
loss and writer health. History retains a rolling seven days; client names remain.

Authenticated endpoints: GET /metrics/summary, /metrics/timeseries,
/metrics/domains, /metrics/clients, /metrics/health, /clients, /clients/{id},
and /requests. PATCH /clients/{id} accepts a required nullable name, requires
quoted global If-Match from GET /status, completes synchronously, and returns
the new ETag. Names are 1–256 UTF-8 bytes with no control characters; null clears.
Telemetry inserts do not advance the configuration revision.

Shared filters: from inclusive, to exclusive, client_id, resolution, exact domain,
numeric query_type, transport, errors. Times accept Unix milliseconds or UTC
YYYY-MM-DDTHH:MM:SSZ. Default last 24 hours, maximum seven days. Limit 1–100,
default 50. Interval 1m/5m/15m/1h with at most 1000 buckets.

Summary returns an object in data; list endpoints return arrays. Envelopes include
from_ms, to_ms, observed_at_ms, interval_ms, data, and nullable next. Timeseries
is sparse: missing buckets have zero recorded events. Clients sort by ID;
requests sort by receive time then ID descending; rankings sort by matching count.
Follow opaque after cursors without changing filters. Cursors freeze request
insertion watermark/time bounds, but retention continues. Client names are current
metadata. Health and individual identity responses are not enveloped.

Outcomes are blocked, cached, forwarded, local, rejected. Errors overlap outcomes.
Forwarded includes attempted upstream requests that fail. Cache hit percentage =
cached / (cached + forwarded), blocked percentage = blocked / total, zero for
empty denominators. Counts cover retained recorded events, never lifetime totals.
SQL reads have a two-second execution deadline and run outside DNS/state locks.
Consult the embedded OpenAPI contract for complete machine-readable schemas.
