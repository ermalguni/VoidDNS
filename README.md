# VoidDNS

## Startup configuration

Run with an explicit JSON configuration path:

```sh
zig build run -- --config examples/voiddns.json
```

For development without privileged-port permissions, copy the example and set
`dns.listen.port` to `5353`, then query with `dig @127.0.0.1 -p 5353 home.test A`.
The built executable accepts `--config <path> [--control-stdin]` or `--help`.
No implicit file search or environment overrides are performed. Relative
configuration paths are resolved against the working directory.

The complete schema is demonstrated in [`examples/voiddns.json`](examples/voiddns.json).
Only `schema_version`, `upstream`, `upstream.servers`, and each server's `address`
are required. Optional sections and fields use the following defaults:

| Field | Default | Accepted values |
| --- | --- | --- |
| `schema_version` | Required | `1` |
| `dns.listen.address` | `"127.0.0.1"` | IPv4 literal |
| `dns.listen.port` | `53` | Integer, 1–65535 |
| `upstream.servers` | Required | Nonempty array of address/port objects |
| `upstream.servers[].address` | Required | IPv4 literal |
| `upstream.servers[].port` | `53` | Integer, 1–65535 |
| `upstream.timeout_ms` | `3000` | Integer, 1–4294967295 |
| `cache.capacity` | `4096` | Nonnegative integer fitting `usize`; zero disables caching |
| `logging.level` | `"info"` | `"err"`, `"warn"`, `"info"`, `"debug"` |

Capacity counts cache slots, not bytes; large values still depend on available
memory. Hostnames and IPv6 transport addresses are not supported. Binding beyond
loopback exposes the DNS service to the selected network; restrict access with
appropriate network controls.

Files are limited to 1 MiB. Parsing rejects unknown and duplicate fields, comments,
trailing commas, wrong types, unsupported versions, and invalid values. Numeric
settings must use unquoted integer tokens, not fractions or exponent notation.
Invalid configuration stops startup before binding the listener. Semantic errors
identify the field, including upstream array indices; JSON syntax errors include
line and column.

All configuration handling lives under `src/config/`:

- `document.zig`: JSON-shaped `Document`, defaults, and standard typed decoding.
  A reflection-driven token contract rejects coercions such as `"port": "53"`,
  fractional/exponent integer fields, and numeric enum tags before decoding.
  There are no custom JSON parsing hooks.
- `config.zig`: semantic validation and conversion to an owned runtime `Config`,
  with binary addresses and independently owned strings.
- `definitions.zig`: normalized, owned filtering definitions converted from a document.
- `manager.zig`: file path ownership, bounded loading, and typed atomic saves.

`document.parse` returns `std.json.Parsed(Document)`; its strings and arrays remain
valid until `deinit`. The input bytes may be released immediately. Access sections
through fields such as `parsed.value.upstream.servers` and `parsed.value.blocks.lists`.
`config.fromDocument` creates an independent runtime snapshot; destroying the
parsed document does not invalidate it. Constructed documents may borrow strings
and slices, which must remain valid through conversion or saving.

Loading and saving validate definitions without fetching lists.
`Config.prepareState` separately builds independent RAM filtering state.
Colocated configuration tests run through `zig build test`.

`main.zig` owns one manager and coordinates DNS generations. Each generation
keeps its configuration, filtering state, upstream pool, cache, and packet buffer
alive until its worker has stopped. The DNS loop uses a concurrent task on Zig
0.16's threaded I/O backend; cancellation wakes blocked I/O and joins the worker
before resources are released. No thread is forcibly terminated.

### Saving and reloading

Enable the local stdin control channel explicitly:

```sh
zig build run -- --config examples/voiddns.json --control-stdin
```

Enter one command per line:

| Command | Behavior |
| --- | --- |
| `reload` | Read the configured file and prepare a replacement DNS generation |
| `save <candidate-file>` | Parse and validate a typed document, serialize and atomically save it to the configured path, then request reload |
| `quit` | Cooperatively stop and join the DNS worker, then exit |

EOF also exits cleanly when stdin control is enabled. Without `--control-stdin`,
stdin is never read. There is no file watcher or signal-based reload: external
edits require `reload` or a process restart. Command lines are limited to 4096
bytes; candidate files remain limited to 1 MiB. Paths after `save` are literal,
not shell-expanded. Relative list paths inside a candidate resolve against the
**target configuration directory**, not the candidate file's directory.

Main alone handles save/reload requests through a bounded synchronized mailbox.
It prepares definitions, source snapshots, cache, and buffers while the old worker
continues serving. Invalid JSON, invalid definitions, or failed imports leave the
old worker untouched. Once preparation succeeds, main cancels and joins the old
worker, then binds and starts the replacement. This introduces a short serving
gap and resets the cache. Preparation temporarily holds both generations in RAM.
If replacement startup fails, main attempts to restart the retained previous
generation without refetching its lists; failed recovery exits with an error.
Source fetching can delay processing later control requests.

Saving writes an exclusive temporary file in the target directory, syncs its
contents, atomically replaces the target, and syncs the directory on supported
POSIX systems. Replacement files use private `0600` permissions, subject to
umask; old permissions are not preserved. Pre-replacement failures retain the
original file. A directory-sync failure after replacement reports that the file
was replaced but durability is uncertain. Saves serialize the typed document with
two-space indentation, explicit defaults, and omitted null optional fields; input
formatting is not preserved. The serialized output must also fit 1 MiB before any
file is replaced. There is no cross-process writer lock.

**Saved does not mean active.** A successful save can be followed by a failed
import or bind. The previous DNS configuration remains active if recovery
succeeds, but the saved file remains the authority for the next reload/startup.
Coordinate external editors with application saves to avoid last-writer-wins
overwrites. This configuration editor does not add persistent API/peer CRUD.
The hard-coded `home.test` A/AAAA example is not configurable through this file.

## Domain filtering and blocklists

```sh
zig build run -- --config examples/voiddns.json
```

[`examples/voiddns.json`](examples/voiddns.json) includes both startup settings and
filtering definitions. It keeps the file-backed `example-domains` list and adds
`first-blocklist`, [HaGeZi Multi PRO mini](https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.mini-onlydomains.txt)
in plain-domain format. Despite the source URL's `/wildcard/` directory, VoidDNS
matches these names exactly; it does not infer subdomain blocking.
The example requires internet access to load that enabled source.

The file is authoritative, not a seed merged with another store. Apply changes
through the explicit reload channel above or restart. Omit `blocks` and `allows`
for empty filtering sets. The separate state file and `--state` flag are removed;
move their `blocks` and `allows` sections into the `--config` file.

```json
{
  "schema_version": 1,
  "upstream": {
    "servers": [{"address": "1.1.1.1"}]
  },
  "blocks": {
    "lists": [
      {
        "id": "tracking",
        "name": "Tracking domains",
        "enabled": true,
        "source": {
          "kind": "url",
          "value": "https://example.org/tracking.txt"
        },
        "format": "domains"
      }
    ],
    "domains": ["blocked.example"]
  },
  "allows": {
    "domains": ["allowed.example"]
  }
}
```

The document requires `schema_version: 1` and the upstream settings described
above. Omitted `blocks`, `allows`, `lists`, and `domains` are empty. Unknown and
duplicate fields, wrong types, and unsupported versions are rejected.
The complete configuration file is limited to 1 MiB.
Every list requires `id`, `source.kind`, `source.value`, and `format`:

| Field | Rules |
| --- | --- |
| `id` | Unique stable ID, 1–128 ASCII letters/digits or `.`, `_`, `-`; changing a display name does not change identity |
| `name` | Optional nonempty display name, up to 256 printable ASCII bytes |
| `enabled` | Defaults to `true`; disabled sources are validated but not loaded |
| `source.kind` | `url` or `file` |
| `source.value` | HTTP/HTTPS URL or filesystem path; URL credentials and fragments are rejected |
| `format` | Required: `domains` for URLs; `domains` or `hosts` for local files |

Relative file sources resolve against the **configuration file's directory**, not
the working directory. Relative `--config` paths resolve against the working directory.
HTTP/HTTPS loads require a successful status; HTTPS uses system CA verification.
Each list is limited to 32 MiB after decompression. Downloads currently have no
whole-request deadline, so an unresponsive source can delay startup.

### Supported list formats

- URL sources accept only one domain per line, blank lines, and `#` comments.
  `format: "hosts"` is rejected for URLs, even when disabled. Hosts rows, Adblock
  rules, HTML, multiple domains on a line, and other invalid content fail the
  complete import rather than being skipped. No format autodetection is performed.
- `domains`: one domain per line, for URL or local-file sources.
- `hosts`: local files only; an IPv4/IPv6 literal followed by one or more domain
  aliases. The address is ignored: imported names always use the sinkhole policy.
- Both accept blank lines, CRLF, and `#` comments, including inline comments.
  Duplicate names are deduplicated. Hosts-format imports ignore customary local
  aliases such as `localhost`, `localhost.localdomain`, and `ip6-localhost`.
- Names are ASCII, case-insensitive, with an optional trailing dot. Labels are
  1–63 bytes, total length at most 253 bytes excluding the trailing dot.
  Letters, digits, hyphens, and underscores are accepted; labels cannot start or
  end with a hyphen. Use ASCII punycode for internationalized names.
- Wildcards, Adblock syntax, URL rules, IP-literal domain entries, and malformed
  lines are rejected. One malformed line rejects the complete import.

Matching is **exact**, never implicit suffix matching: blocking `example.org`
does not block `www.example.org`.

### Precedence and responses

1. Explicit block → sinkhole, even if also explicitly allowed or local.
2. Explicit allow → bypass imported lists; use a matching local answer, otherwise
   cache/upstream.
3. Matching local DNS record → local answer.
4. Imported block → sinkhole.
5. Otherwise → cache/upstream.

A matching local answer currently means an available IN `A`/`AAAA` record for
the requested type. Blocked IN `A` requests receive `0.0.0.0`; blocked IN `AAAA`
requests receive `::`. Both use TTL zero. Other blocked types/classes receive
`NOERROR` with no answer records (NODATA), without an authority SOA.
Generated local and sinkhole answers are not inserted into the response cache.
Malformed/unsupported DNS questions are rejected rather than forwarded around
the policy checks.

### Ownership, updates, and limits

All enabled lists must load successfully **before binding the listener**. Missing
files, failed downloads, malformed content, or invalid definitions stop startup.
Definitions survive restarts in the configuration file; downloaded snapshots do not.
Each restart or reload fetches the configured sources, so offline activation
requires locally available sources. No management HTTP endpoints, automatic
refresh scheduler, file watcher, or peer synchronization are implemented.

The in-process blocklist service supports add, replace, refresh, and remove.
Failed replacements/refreshes retain the previous complete snapshot. Source
membership is preserved: deleting or refreshing one source cannot remove a name
still provided by another. Explicit blocks remain independent of imported names.
These mutation operations require exclusive access. Each DNS worker reads its
own fully prepared state; main joins it before reclaiming that state. Reload
preparation never mutates the active generation's indexes.

- `domains/domain.zig` and `domains/store.zig`: normalization and explicit sets.
- `blocklist/source.zig`, `fetch.zig`, `parse.zig`: definitions and bounded import.
- `blocklist/index.zig`: RAM hash index with one interned name per unique domain,
  membership counts, and per-source slices referencing those names.
- `blocklist/service.zig`: owned source lifecycle and transactional replacement.
- `state/state.zig`, `state/filtering.zig`: state ownership and construction from typed configuration definitions.
- `policy/policy.zig`: precedence; `resolver/resolver.zig`: response construction
  and policy-before-cache dispatch.

Queries perform allocation-free RAM lookups; list I/O and parsing never run in
the DNS query path. Colocated parser, membership, refresh, state, and resolver
tests run through `zig build test`.

## Upstream resolvers

Each DNS generation owns a round-robin pool, which borrows its configuration's
parsed IPv4 upstream address list until the worker joins. The example uses
`1.1.1.1:53`, `8.8.8.8:53`, then repeats. There is no implicit upstream list when
configuration is missing. Addresses are parsed before activation; an empty list
is rejected.

Only forwarded queries advance the rotation. Cache hits and local answers do not.
An exchange failure still advances the rotation for the next query; there is no
automatic retry or failover within a query. `upstream.timeout_ms` controls the
single response deadline, defaulting to three seconds. Ignored upstream packets
do not reset that deadline.

The pool is used by the sequential UDP serving loop. Concurrent forwarding would
require synchronization of its index. Upstream sockets currently use IPv4.

## DNS cache

Responses are looked up in the RAM cache only after filtering policy and local
answers. Only upstream responses are inserted. `cache.capacity` configures the
slot count; record TTLs determine expiry.
Hits age returned TTLs without extending expiry.

The cache uses direct-mapped slots and exact-sized packet storage. Hash collisions
replace entries. Responses larger than 4096 bytes, queries with EDNS options
other than COOKIE, transaction-authenticated responses, and truncated responses
bypass caching.

Negative responses require an authority SOA and respect its negative-cache TTL.
The cache belongs to one sequential DNS worker and is replaced on successful
reload. Concurrent access within a worker would require synchronization.

Cache responsibilities are split across three files:

- `src/cache/cache.zig`: slot allocation, lookup, expiration, and replacement.
- `src/cache/key.zig`: query eligibility and borrowed, transaction-ID-independent
  key bytes. The resolver saves these bytes before the response overwrites its buffer.
- `src/cache/entry.zig`: response validation, packed entry allocation/freeing, and
  replay with the client's transaction ID and aged TTLs.

Each entry still uses one exact-sized allocation containing its key, response,
and TTL offsets. The cache owns entries; entry creation and destruction use the
cache's allocator. This split adds no allocation or packet copy to the query path.

### DNS cookies

VoidDNS ignores DNS cookies; it does not provide cookie-based protection.
COOKIE options are stripped before cache lookup and upstream forwarding.
Different client cookies and a cookie-free query share a cache entry when the
remaining query fields match. The EDNS UDP payload size, version, DO flag, and
other options are preserved; options such as Client Subnet still bypass caching.
Requests without cookies do not require a normalization copy.

Unsolicited upstream cookies are removed before caching or replying. The usual
final OPT record is compacted and its RDLEN updated. For requests with records
after OPT, COOKIE is replaced by zero-filled EDNS Padding to preserve compression
offsets; these requests still bypass caching. A response with an unsolicited
cookie in a non-final OPT is rejected rather than shifting compressed records or
adding unsolicited padding. Signed messages containing cookies are rejected
rather than invalidating their signatures. Malformed EDNS framing is rejected.

After rebuilding and restarting, repeated `dig @127.0.0.1 coordimap.com A`
queries can hit the cache without `+nocookie`, subject to DNS TTL expiry.

## Logging

Logs are written to stderr using Zig's standard logger through `src/logging.zig`.
`logging.level` selects the runtime threshold; each level includes more severe
messages. All levels remain compiled in. The default `"info"` suppresses per-query
logs; select `"debug"` when diagnosing individual requests.

- `server`: client IP/port, queried domain, query type and class, and transaction
  ID before resolution (including cache hits). A and AAAA have readable type
  names; other types retain their numeric code. Resolution and reply failures
  include the client and transaction ID.
- `resolver`: query COOKIE removal and unsolicited response COOKIE removal.
  Cookie values are not logged.
- `cache`: initialization, hits, misses, expiry, slot replacement, insertion,
  and cache bypasses. Events include DNS transaction IDs when available,
  response sizes, and cache lifetimes.
- `upstream`: forwarding destination, received response size and RCODE,
  ignored-packet reasons, and forwarding failures (including receive timeouts).
  Forwarding failures use warning level.
- `blocklist`: source ID/name, lifecycle action, imported count, unique total,
  and import failures. Source URLs and filesystem paths are not logged by the
  blocklist service.

Binding port 53 requires appropriate permissions. Debug request logs contain
client addresses and queried domains;
restrict access and retention accordingly. Names use a trailing root dot and
decimal escapes for special bytes to prevent ambiguous names or injected log
lines. Raw DNS packets are not logged.

Verbose per-query logging adds I/O overhead and should be disabled when measuring
DNS throughput. At `"info"` or a more restrictive level, request-name decoding
and formatting for logging are skipped at runtime.
