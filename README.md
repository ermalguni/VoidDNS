# VoidDNS

## Startup configuration

Run with an explicit JSON configuration path:

```sh
zig build run -- --config examples/voiddns.json
```

For development without privileged-port permissions, copy the example and set
`dns.listen.port` to `5353`, then query with `dig @127.0.0.1 -p 5353 home.test A`.
The built executable accepts `--config <path>` or `--help`. No implicit file
search or environment overrides are performed. Relative configuration paths are
resolved against the working directory.

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

`src/config.zig` reads and validates the file once and converts address strings
into binary addresses. It retains only the owned upstream address array; JSON
buffers and parser allocations are released before serving. `main.zig` keeps
configuration alive while the upstream pool borrows it and passes individual
settings into services. Colocated configuration tests run through `zig build test`.

The daemon never rewrites the file. Changes require a restart; there is no live
reload. This file owns local startup settings, not API/peer-managed records,
allow/block entries, or blocklist sources. Managed-state persistence remains a
separate design decision. The existing hard-coded `home.test` A/AAAA example is
unchanged and is not configurable through this file.

## Upstream resolvers

`src/main.zig` owns the round-robin pool, which borrows the configuration's
parsed IPv4 upstream address list. The example configuration uses `1.1.1.1:53`,
`8.8.8.8:53`, then repeats. There is no implicit upstream list when configuration
is missing. Addresses are parsed once at startup; an empty list is rejected.

Only forwarded queries advance the rotation. Cache hits and local answers do not.
An exchange failure still advances the rotation for the next query; there is no
automatic retry or failover within a query. `upstream.timeout_ms` controls the
single response deadline, defaulting to three seconds. Ignored upstream packets
do not reset that deadline.

The pool is used by the sequential UDP serving loop. Concurrent forwarding would
require synchronization of its index. Upstream sockets currently use IPv4.

## DNS cache

Responses are cached in RAM before checking local records or forwarding upstream.
`cache.capacity` configures the slot count; record TTLs determine expiry.
Hits age returned TTLs without extending expiry.

The cache uses direct-mapped slots and exact-sized packet storage. Hash collisions
replace entries. Responses larger than 4096 bytes, queries with EDNS options
other than COOKIE, transaction-authenticated responses, and truncated responses
bypass caching.

Negative responses require an authority SOA and respect its negative-cache TTL.
The cache is owned by the current single-threaded UDP server; concurrent access
requires synchronization.

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

Binding port 53 requires appropriate permissions. Debug request logs contain
client addresses and queried domains;
restrict access and retention accordingly. Names use a trailing root dot and
decimal escapes for special bytes to prevent ambiguous names or injected log
lines. Raw DNS packets are not logged.

Verbose per-query logging adds I/O overhead and should be disabled when measuring
DNS throughput. At `"info"` or a more restrictive level, request-name decoding
and formatting for logging are skipped at runtime.
