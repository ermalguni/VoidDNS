# VoidDNS

## DNS cache

Responses are cached in RAM before checking local records or forwarding upstream.
Cache capacity is configured in `main.zig`; record TTLs determine expiry.
Hits age returned TTLs without extending expiry.

The cache uses direct-mapped slots and exact-sized packet storage. Hash collisions
replace entries. Responses larger than 4096 bytes, queries with EDNS options
other than COOKIE, transaction-authenticated responses, and truncated responses
bypass caching.

Negative responses require an authority SOA and respect its negative-cache TTL.
The cache is owned by the current single-threaded UDP server; concurrent access
requires synchronization.

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

Logs are written to stderr using Zig's standard logger. `std_options.log_level`
in `src/main.zig` is set to `.debug` so per-query activity is visible.
Use `.info` for normal operation or benchmarking to suppress per-query logs.

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

Run with `zig build run`. Binding the configured port 53 requires appropriate
permissions. Debug request logs contain client addresses and queried domains;
restrict access and retention accordingly. Names use a trailing root dot and
decimal escapes for special bytes to prevent ambiguous names or injected log
lines. Raw DNS packets are not logged.

Verbose per-query logging adds I/O overhead and should be disabled when measuring
DNS throughput. At `.info`, request-name decoding and formatting for logging are
skipped.
