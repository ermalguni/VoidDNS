# VoidDNS

## Web management UI

`ui/` contains the React + TypeScript management application, using Vite,
Mantine, React Router, and TanStack Query. It supports overview/cache clearing,
domain rules, local A/AAAA record sets, blocklist CRUD and refresh, runtime
settings, complete configuration validation/replacement/reload, and policy checks.
The UI and authenticated API share the embedded HTTP listener; neither runs in
the DNS query path.

The configuration editor uses Mantine `JsonInput` with two-space indentation on
load and blur, plus inline JSON syntax errors. Active-state review panels are
indented too. Formatting changes whitespace only: large integers, numeric
notation, duplicate keys, and string escapes remain intact for server validation.
Invalid drafts remain untouched.

Keep the administrator key file private and outside the frontend directory.
For frontend development, use Node.js 22.12+ and npm:

```sh
cd ui
npm ci
npm run dev
```

Open the local Vite URL and enter the existing administrator API key. The dev
server binds to loopback and proxies `/api/v1` to `http://127.0.0.1:8080`.
For a different backend, start it with
`VOID_DNS_API=http://127.0.0.1:18080 npm run dev`. This variable configures only
the development/preview proxy; it is not embedded into browser assets.
Never put credentials in a `VITE_*` variable or committed source.

```sh
npm run build
```

This regenerates API types from `src/api/openapi.json`, checks TypeScript, and
produces static assets in `ui/dist/`. `npm run generate` refreshes types alone.
`npm run preview` is a local build smoke check, not a production server.
Use a modern browser supporting `Promise.withResolvers`.

Production builds embed `ui/dist/` in the Zig executable. One VoidDNS process
serves the public UI and authenticated `/api/v1` namespace on the shared
`api.listen` listener, default **http://127.0.0.1:8080**. Node.js is build-only;
no separate UI server, launcher, or reverse proxy is required.
UI assets do not contain an API key. Frontend routes `/`, `/domains`, `/records`,
`/blocklists`, `/policy`, `/settings`, and `/configuration` support direct navigation;
unknown routes and missing assets return `404`.
Keep management HTTP on loopback or a restricted network. Remote access requires
HTTPS termination and appropriate network controls.

The login field accepts any nonempty key without client-side length limits.
The backend accepts arbitrary key-file contents without length or character
restrictions; HTTP header rules still constrain keys sent by clients.

The API key stays in tab memory, not browser storage; reloading or signing out
clears the UI session. Only the theme preference is stored locally. Signing out
does not cancel accepted server operations. Writes are never automatically
retried: the UI polls accepted operations and reports saved, active, and
durability results. A failed activation can leave disk and runtime different.
Conflicts preserve editor drafts and require explicit current-state review;
expired pagination cursors restart the listing. If polling is interrupted, use
**Resume operation polling** before another write; after a server restart,
sign out and reconnect because operation IDs and revisions are process-local.

## Building

Use Zig 0.17.1 and a matching ZLS version for editor diagnostics.

On a fresh dependency cache, prefetch the pinned transitive packages through Git:

```sh
zig fetch git+https://github.com/karlseguin/metrics.zig#ac167295b6a8fd84ca7af852c1032e6b246101f0
zig fetch git+https://github.com/karlseguin/websocket.zig#f2b3bad6875595e8dd42c726e8e914885a8b0ba0
```

This avoids the nested-root archive-cache/hash mismatch observed with this
Zig 0.17.1 installation and GitHub tarballs. Build the UI before compiling Zig:

```sh
(cd ui && npm ci && npm run build)
zig build
zig build test
zig build run -- --help
```

Arguments after `--` are forwarded to VoidDNS through the build system's
`addPassthruArgs` API. The source and pinned HTTP dependency now target Zig 0.17.

`zig build` invokes the Node.js 22 embedding tool `ui/embed.mjs` against
`ui/dist/`; keep Node available through compilation. The UI must already be built.

## Linux binaries and packages

[Linux binaries, packages, and containers](.github/workflows/linux-packages.yml) runs when
you push a `vX.Y.Z` tag or select **Run workflow** in GitHub Actions and enter
an `X.Y.Z` version. Only three-component numeric versions are accepted.
Manual builds default to `0.0.0`; use the intended release version when distributing
packages. Each architecture produces a binary `.tar.gz`, Debian `.deb`, Fedora
`.rpm`, Arch `.pkg.tar.zst`, and `SHA256SUMS-<architecture>`.

| Binary target | Intended systems | Debian | Fedora | Arch / Arch Linux ARM |
| --- | --- | --- | --- | --- |
| x86_64 | 64-bit Intel/AMD Linux | amd64 | x86_64 | x86_64 |
| aarch64 | 64-bit ARM Linux / Raspberry Pi OS | arm64 | aarch64 | aarch64 |
| armv7 | 32-bit ARMv7 hard-float Linux / Raspberry Pi OS | armhf | armv7hl | armv7h |

Select the architecture of the installed OS, not just the processor. ARMv7
covers Pi 2 and newer, including Zero 2; original Pi 1 and Pi Zero/Zero W
ARMv6 systems are not supported. Package generation does not imply that each
distribution still supports every architecture.

The workflow cross-compiles with Zig 0.17.1, `ReleaseFast`, and generic CPU
targets, using musl targets to avoid a host glibc dependency. It runs `--help`
for each binary (under QEMU for ARM), then uses pinned nFPM 2.43.4 to build all
three package formats from [one manifest](packaging/nfpm.yaml).

After all three builds succeed, the workflow publishes every archive, package,
and architecture-specific checksum file to the GitHub Release named `vX.Y.Z`.
A manual run creates that tag at the selected commit if it does not exist;
if the tag already exists, it must point to the commit being built. Rerunning
the workflow updates the existing release assets with matching filenames.
Only the release job receives `contents: write` permission.

Download your architecture's files from the repository's **Releases** page.
Workflow artifacts are also retained for 30 days; release assets do not have
that artifact expiration. Download all four files for your architecture and its
checksum file, then run, for example, `sha256sum -c SHA256SUMS-aarch64`.
The workflow does not sign packages or upload to distribution repositories.
Install the appropriate package using one of:

```sh
sudo apt install ./voiddns_*.deb
sudo dnf install ./voiddns*.rpm
sudo pacman -U ./voiddns*.pkg.tar.zst
```

Packages install `/usr/bin/VoidDNS`, documentation, the MIT license, examples,
and one `voiddns.service`. They require `ca-certificates` for HTTPS blocklist
downloads. Installation also copies `voiddns.json` and `blocked-domains.txt` into
`/etc/voiddns` and generates a unique 256-bit hexadecimal API key in
`/etc/voiddns/api.key` (no trailing newline). The directory is mode `0750`; new
configuration, blocklist, and key files are mode `0600`, owned by `voiddns`.
Existing files, including credentials, are never overwritten on installation
or upgrade. The public development key in `examples/api.key` is not installed.

The service runs as `User=voiddns`, with working and configuration directory
`/etc/voiddns`, and only the DNS bind capability (`CAP_NET_BIND_SERVICE`).
Installation enables and starts it when systemd is running. The example binds
DNS to `127.0.0.1:53` and the UI/API to `127.0.0.1:8080`; enabled URL blocklists
require network access at startup. A port already in use or an unavailable
source can prevent startup.

Open `http://127.0.0.1:8080` and use the generated key to authenticate.
To display it:

```sh
sudo cat /etc/voiddns/api.key; printf '\n'
```

Edit `/etc/voiddns/voiddns.json` to customize listeners, upstreams, and filtering,
then run `sudo systemctl restart voiddns.service`. Keep the directory and JSON
writable by `voiddns` for API saves: atomic replacement creates a temporary file
in the same directory.

Binding port 53 requires appropriate privileges; use port 5353 for an
unprivileged smoke test. For the standalone archive, extract it and run
`./VoidDNS --config /path/to/voiddns.json`; install system CA certificates
separately if using HTTPS sources.

Manage the service with `systemctl status|start|stop voiddns.service`.
Archives contain the executable with the production UI embedded; run
`./VoidDNS --config /path/to/voiddns.json`. Node.js is not needed on deployment
hosts.

### Docker images

After the GitHub Release succeeds, the same workflow publishes
`ghcr.io/<owner>/<repository>:vX.Y.Z` (owner/repository lowercased).
One multi-platform tag contains `linux/amd64`, `linux/arm64`, and `linux/arm/v7`;
Docker selects the host architecture automatically. ARMv6 is not supported.
There is no floating `latest` tag. Rerunning a version replaces its image tag;
pin an image digest when immutable deployment is required.
The main Alpine image runs a single VoidDNS process with the UI embedded.
There is no standalone UI image or proxy target setting.

The container job alone receives `packages: write`. It reuses the checksummed
release binaries and pushes to GitHub Container Registry using `GITHUB_TOKEN`.
GHCR package visibility may
need to be changed to public for anonymous pulls; private images require
`docker login ghcr.io`.

The [Dockerfile](Dockerfile) uses Alpine with CA certificates for HTTPS imports,
runs as UID/GID `65532:65532`, and defaults to
`--config /config/voiddns.json`. No configuration or credentials are embedded.

Copy both example files into a host directory, then edit `voiddns.json`:
set `dns.listen.address` to `0.0.0.0`, `dns.listen.port` to `5353`, and
`api.listen` to `{"address":"0.0.0.0","port":8080}`. Create the private API key
before starting. Container loopback is not reachable through published ports.

```sh
mkdir -p container-config
cp examples/voiddns.json examples/blocked-domains.txt container-config/
# Edit container-config/voiddns.json as described above.
docker run -d --init --name voiddns \
  --cap-drop ALL --read-only --tmpfs /tmp \
  -p 53:5353/udp \
  -p 127.0.0.1:8081:8080 \
  --mount type=bind,src="$(pwd)/container-config",dst=/config \
  ghcr.io/<owner>/<repository>:vX.Y.Z
```

Replace the image placeholder with your repository and release version.
The host directory must be traversable and its input files readable by UID
65532. For API persistence, make the directory and configuration writable by
that UID: mount the **directory**, not just the JSON file, because saves use
same-directory temporary files and atomic replacement. API key files must be
owned by UID 65532 with mode `0600`. For DNS-only use without persistent edits,
the configuration mount can be read-only.

#### Docker Compose

The root `compose.yaml` publishes **host UDP and TCP port 53** to container port
5353, allowing the non-root process to run with all capabilities dropped.
Host port 53 must be available for both transports.

Compose binds the existing `examples` directory directly. Configure both listeners
for container networking before starting:

```sh
python3 - <<'PY'
import json
from pathlib import Path

path = Path("examples/voiddns.json")
config = json.loads(path.read_text())
config["dns"]["listen"] = {"address": "0.0.0.0", "port": 5353}
config["api"] = {**config.get("api", {}), "enabled": True,
                 "listen": {"address": "0.0.0.0", "port": 8080},
                 "key_file": "api.key"}
config["ui"] = {"enabled": True}
path.write_text(json.dumps(config, indent=2) + "\n")
PY
```

The JSON and `blocked-domains.txt` are mounted together at `/config`, so the
relative blocklist path resolves correctly. No configuration copy is needed.
The directory mount preserves atomic saves; API updates will modify the
files in `examples` directly. Create a private API key (without a trailing
newline), then give the container access. These commands change ownership of
the example directory and JSON so API saves can atomically replace it:

```sh
(umask 077; openssl rand -hex 32 | tr -d '\n' > examples/api.key)
sudo chown 65532:65532 examples examples/voiddns.json examples/api.key
sudo chmod 600 examples/api.key
```

Set the image to a published version or digest, then start:

```sh
export VOIDDNS_IMAGE=ghcr.io/<owner>/<repository>:vX.Y.Z
docker compose up -d
docker compose logs -f voiddns
```

Open **http://127.0.0.1:8081** and sign in with the exact contents of `api.key`.
The one shared management port is published on host loopback; no proxy is used.
Remote access requires an HTTPS reverse proxy and network controls; do not
expose this plaintext UI port directly to the Internet.

Replace the image placeholder before running. For locally built images,
use `VOIDDNS_IMAGE=voiddns:local`. The configuration remains operator-owned;
Compose does not overwrite it on restart. No separate UI image is required.
For DNS-only operation, set both `api.enabled` and `ui.enabled` to `false`;
no HTTP listener starts. UI-only operation is invalid.

DNS accepts UDP and TCP. Signal-based graceful shutdown is not
implemented; for cooperative shutdown, start with `-i` and append
`--config /config/voiddns.json --control-stdin`, then send `quit` through stdin.

To build a native amd64 image locally using Zig 0.17.1 (prefetch dependencies
as described above):

```sh
(cd ui && npm ci && npm run build)
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl -Dcpu=baseline
docker build --platform linux/amd64 \
  --build-arg BINARY_PATH=zig-out/bin/VoidDNS -t voiddns:local .
docker run --rm --platform linux/amd64 voiddns:local --help
```

For ARM64 use `aarch64-linux-musl`, `baseline`, and `linux/arm64`; for ARMv7
use `arm-linux-musleabihf`, `generic+v7a`, and `linux/arm/v7`. Running foreign
images requires QEMU/binfmt support. Without the `BINARY_PATH` override,
Docker expects prebuilt binaries under `container-bin/amd64/VoidDNS`,
`container-bin/arm64/VoidDNS`, and `container-bin/armv7/VoidDNS`, as populated
by the workflow; the Dockerfile does not download a compiler or build Zig.
The release workflow builds the UI first with Node.js 22 and the npm lockfile,
then embeds those assets in each architecture's executable.

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
`schema_version`, non-null `api` and `ui` objects, `upstream`, `upstream.servers`,
and each server's `address` are required. Other sections and fields use defaults:

| Field | Default | Accepted values |
| --- | --- | --- |
| `schema_version` | Required | `2` only |
| `dns.listen.address` | `"127.0.0.1"` | IPv4 literal |
| `dns.listen.port` | `53` | Integer, 1–65535 |
| `dns.tcp.max_connections` | `64` | Positive u32; excess accepted connections are closed |
| `dns.tcp.idle_timeout_ms` | `10000` | Positive u32; wait for the first byte of the next frame |
| `dns.tcp.read_timeout_ms` | `5000` | Positive u32; complete-frame deadline after its first byte |
| `dns.tcp.write_timeout_ms` | `5000` | Positive u32; complete-response write deadline |
| `upstream.servers` | Required | Nonempty array of address/port objects |
| `upstream.servers[].address` | Required | IPv4 literal |
| `upstream.servers[].port` | `53` | Integer, 1–65535 |
| `upstream.timeout_ms` | `3000` | Integer, 1–4294967295 |
| `cache.capacity` | `4096` | Nonnegative integer fitting `usize`; zero disables caching |
| `cache.min_positive_ttl_seconds` | `0` | Integer, 0–4294967295; minimum internal positive-response retention, zero respects upstream TTL |
| `logging.level` | `"info"` | `"err"`, `"warn"`, `"info"`, `"debug"` |
| `records` | `[]` | Local IN A/AAAA record sets; see below |
| `api` | Required non-null object | Shared management HTTP configuration |
| `api.enabled` | `true` | Boolean |
| `api.listen.address`, `api.listen.port` | `"127.0.0.1"`, `8080` | IPv4 literal and port 1–65535 |
| `api.key_file` | Required when enabled | Restricted file containing the exact API key bytes |
| `api.file_root` | Omitted | Root for API-managed relative file sources; omission denies them |
| `api.allow_private_sources` | `false` | Explicitly permit private-network API URL sources |
| `ui` | Required non-null object | Embedded frontend configuration |
| `ui.enabled` | `true` | Boolean; requires `api.enabled = true` |

| `api.enabled` | `ui.enabled` | Behavior |
| --- | --- | --- |
| `true` | `true` | Public UI and authenticated API on the shared listener |
| `true` | `false` | Authenticated API only; frontend requests return `404` |
| `false` | `false` | DNS only; no HTTP listener or API key loading |
| `false` | `true` | Invalid configuration |

Schema 1 is a breaking migration with no compatibility mode. Change
`schema_version` to `2` and add explicit `api` and `ui` objects. For a former
DNS-only configuration use `"api":{"enabled":false},"ui":{"enabled":false}`.
For management access retain/configure `api.key_file` and use `"ui":{}` (enabled
by default). Omission or `null` is not equivalent to disabling either object.

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

`main.zig` owns one manager, the active configuration, managed RAM state, and a
long-lived DNS worker. Configuration snapshots and worker resources have separate
lifetimes. The DNS loop uses a concurrent task on Zig 0.17's threaded I/O backend;
cancellation wakes blocked I/O and joins the worker before shutdown or listener
replacement. No thread is forcibly terminated.

### Saving and reloading

Enable the local stdin control channel explicitly:

```sh
zig build run -- --config examples/voiddns.json --control-stdin
```

Enter one command per line:

| Command | Behavior |
| --- | --- |
| `reload` | Validate the configured file and atomically apply its semantic differences |
| `refresh <source-id>` | Reload the contents of one currently active source definition |
| `refresh-all` | Reload all enabled source contents in one transaction |
| `save <candidate-file>` | Parse and validate a typed document, serialize and atomically save it to the configured path, then request reload |
| `quit` | Cooperatively stop and join the DNS worker, then exit |

EOF also exits cleanly when stdin control is enabled. Without `--control-stdin`,
stdin is never read. There is no file watcher or signal-based reload: external
edits require `reload` or a process restart. Command lines are limited to 4096
bytes; candidate files remain limited to 1 MiB. Paths after `save` are literal,
not shell-expanded. Relative list paths inside a candidate resolve against the
**target configuration directory**, not the candidate file's directory.

Main alone handles save/reload/refresh requests through a bounded synchronized
mailbox. Reload validates the entire document, then compares normalized records,
explicit rules, and source definitions with the last successfully applied state.
Whitespace, equivalent domain spelling, and record/source collection order do not
trigger changes. RRset address order remains significant because it controls
answer order. A semantically unchanged reload retains DNS resources.
Every completed management operation advances its revision.

| Change | Runtime work |
| --- | --- |
| Record added, removed, addresses/TTL changed | Publish the new record collection, retaining unchanged name/address allocations |
| Explicit allow/block changed | Add/remove only affected normalized names |
| Enabled source added or enabled | Load only that source and add its memberships |
| Source removed or disabled | Release only its memberships; disabling retains the definition, not its contents |
| Enabled source URL/path/format changed | Prepare and replace only that source's snapshot |
| Source display name changed | Update metadata without source I/O |
| Log level changed | Update the atomic threshold |
| Upstream timeout changed | Update the pool timeout at a query boundary, retaining cache and rotation |
| Upstream servers changed | Replace the pool and clear the upstream response cache |
| Cache capacity changed | Replace only the cache; zero disables it |
| Minimum positive cache TTL changed | Replace only the cache, clearing existing responses and applying the new retention policy |
| Listener address/port changed | Cancel/join and rebind the worker, retaining unchanged resources |

**Reload is not refresh.** An unchanged file path or URL retains its last imported
snapshot even if its contents changed or the source is now unavailable. Use
`refresh <source-id>` or `refresh-all` to import new contents. These commands use
the active definitions, not unapplied edits in the configuration file. Refreshing
a disabled source is a no-op; an unknown source ID is rejected. Refresh-all is
all-or-nothing across enabled sources. Restart still loads every enabled source.

Fetching, parsing, and staging happen while DNS continues serving. Every
fallible reservation completes before publication; any invalid configuration,
failed import, or allocation failure rejects the whole candidate. Main commits
the prepared source/rule/record changes under the state publication mutex. DNS
holds that mutex only through policy lookup and local-answer construction, never
through cache/upstream I/O. A query already past its policy check may finish with
the preceding policy. Large source commits still take time proportional to their
changed memberships and can briefly delay policy lookups.

Record/filtering-only changes preserve the listener, worker generation, and
response cache. Local answers and policy precede cache lookup; deleting a local
record may expose a still-valid upstream cache entry. Runtime pool/cache changes
wait for the current resolution to finish. Listener changes alone require a
serving gap: if replacement startup fails, main restores the previous listener
without publishing any candidate changes or discarding its cache. Failed listener
recovery exits with an error. Preparation retains old data plus staged changes,
not a second copy of every imported list. Source fetching can delay processing
later control requests.

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
overwrites. API CRUD also persists through this configuration file; peer-managed
durability and synchronization remain unimplemented.
The configuration remains authoritative: records/rules/source definitions absent
from a successful candidate are removed. Records are identified by normalized
name/type, rules by normalized name/action, and sources by their stable ID.

### Custom DNS records

The optional top-level `records` array contains one entry per name and type:

```json
"records": [
  {
    "name": "home.test",
    "type": "A",
    "ttl": 60,
    "addresses": ["192.0.2.10", "192.0.2.11"]
  },
  {
    "name": "home.test",
    "type": "AAAA",
    "ttl": 60,
    "addresses": ["2001:db8::10", "2001:db8::11"]
  }
]
```

`name`, `type`, and `addresses` are required. Names use the exact-name
normalization rules below; types must be `"A"` or `"AAAA"`. Each entry accepts
1–16 IP literals of its declared family. Binary duplicate addresses are removed,
preserving first occurrence. Duplicate normalized name/type pairs are rejected,
even when their TTLs agree. `ttl` defaults to 60 seconds and accepts unsigned
32-bit integers including zero. Invalid entries reject the entire configuration.

An IN query receives every address in the matching set with the shared TTL,
not a randomly selected address. If the complete set cannot fit the client's
UDP limit (512 bytes without EDNS, at least 512 with EDNS), the response contains
only the question and the TC flag; no partial set is returned. Clients can retry
over TCP for the complete set; TCP ignores EDNS's UDP payload limit.
A missing name/type continues through filtering and
cache/upstream resolution; an A-only entry does not suppress upstream AAAA.
Explicit blocks still override local records. Generated answers are not cached.

Omitting `records` or using `[]` supplies no local records. There is no implicit
`home.test`; the example configuration now defines it explicitly.
The JSON-facing entries are available through `Document.records`.
`Config.records` owns normalized names and tagged binary address slices
(`.a: []const [4]u8` or `.aaaa: []const [16]u8`) with `ttl_seconds`.
All parsing and allocation happens during configuration loading, not queries.

## Domain filtering and blocklists

```sh
zig build run -- --config examples/voiddns.json
```

[`examples/voiddns.json`](examples/voiddns.json) includes both startup settings and
filtering definitions. It keeps the file-backed `example-domains` list and adds
`first-blocklist`, [HaGeZi Multi PRO mini](https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.mini-onlydomains.txt)
in plain-domain format. Despite the source URL's `/wildcard/` directory, VoidDNS
matches these names exactly; it does not infer subdomain blocking.
The example also includes selected advertising, tracking, and security feeds
from [netguide.io's Blocklists for Pi-hole](https://netguide.io/en/blocklists-for-pihole/):

| Source IDs | Purpose | Enabled |
| --- | --- | --- |
| `firebog-adguard`, `firebog-admiral`, `firebog-easylist` | Advertising | Yes |
| `firebog-easyprivacy`, `firebog-prigent-ads` | Tracking and advertising | Yes |
| `matomo-referrer-spam` | Referrer spam | Yes |
| `phishing-army` | Phishing Army extended | Yes |
| `perflyst-android`, `perflyst-smarttv`, `perflyst-firetv` | Device tracking | No; opt in for relevant devices |

All ten added URLs were downloaded and their complete contents passed VoidDNS's
strict domain parser when added. This is a compatible selection, not a copy of
every list on that page: remote hosts files, Adblock rules, and regex entries
are not supported URL imports. Content-category and whole-service blocking
lists were not selected. Device lists are disabled by default because they can
affect device features; enable them individually after reviewing their contents.

The example requires internet access for its enabled URL sources. These feeds
can overlap with HaGeZi and each other, increasing download time and RAM usage.
Any enabled source failing to load or parse prevents startup; upstream contents
can change after validation. Disable unwanted sources rather than assuming all
Pi-hole lists are compatible. Matching remains exact, including for these feeds.

The file is authoritative, not a seed merged with another store. Apply changes
through the explicit reload channel above or restart. Omit `blocks` and `allows`
for empty filtering sets. The separate state file and `--state` flag are removed;
move their `blocks` and `allows` sections into the `--config` file.

```json
{
  "schema_version": 2,
  "api": {"enabled": false},
  "ui": {"enabled": false},
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

The document requires `schema_version: 2`, non-null `api` and `ui` objects, and
the upstream settings described above. Omitted `blocks`, `allows`, `lists`, and
`domains` are empty. Unknown and
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
Each list is limited to 32 MiB after decompression. Every source load has a
30-second whole-load deadline, including DNS resolution and response decoding.

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
Each restart fetches every enabled source. Reload retains unchanged snapshots,
so unrelated record edits work even when an existing source is unavailable.
The management HTTP API supports persistent CRUD and explicit refresh. No
automatic refresh scheduler, file watcher, or peer synchronization is implemented.

The in-process blocklist service supports add, replace, refresh, and remove.
Failed replacements/refreshes retain the previous complete snapshot. Source
membership is preserved: deleting or refreshing one source cannot remove a name
still provided by another. Explicit blocks remain independent of imported names.
Mutation commits require the publication mutex. Main is the sole writer and
prepares source contents outside that mutex; it never changes live memberships
until all participating plans have reserved capacity successfully. Queries cannot
borrow managed strings or records beyond their guarded answer construction.

- `domains/domain.zig` and `domains/store.zig`: normalization and explicit sets.
- `blocklist/source.zig`, `fetch.zig`, `parse.zig`: definitions and bounded import.
- `blocklist/index.zig`: RAM hash index with one interned name per unique domain,
  membership counts, and per-source slices referencing those names.
- `blocklist/service.zig`: owned source lifecycle and transactional replacement.
- `state/state.zig`, `state/filtering.zig`: state ownership and startup construction.
- `state/apply.zig`: prepared source/rule/record diffs and atomic publication.
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
resolver failover within a query. A truncated upstream UDP response retries the
same resolver over TCP. `upstream.timeout_ms` bounds the entire UDP/TCP exchange,
including connect, framed writes, and framed reads; ignored packets do not reset it.

UDP and TCP clients share the RAM cache and upstream rotation under the worker's
runtime mutex; resolution remains serialized. Idle clients and response writes
do not hold that mutex. Upstream sockets currently use IPv4.

### Incoming DNS over TCP

Both DNS listeners use `dns.listen`. Startup requires both binds to succeed.
TCP supports two-byte big-endian framing, messages up to 65,535 bytes, persistent
connections, and pipelining processed in request order. Incomplete, invalid, or
timed-out frames close only their connection. Shutdown and listener replacement
cooperatively cancel and join all clients.

Each admitted connection owns one reusable 65,535-byte packet buffer; there is
no per-query transport allocation. Connection limits and deadlines live under
`dns.tcp`; changes apply to new connections without rebinding. Existing clients
retain their admission-time settings. Lowering the limit does not evict existing
clients; no new clients are admitted until the active count is below the limit.
The kernel backlog and I/O task/socket overhead are additional to packet buffers.

Use `dig +tcp @127.0.0.1 -p 5353 home.test A` to request TCP explicitly.
Oversized cache/upstream answers sent to UDP clients become question-only TC
responses; eligible complete upstream answers remain cached (the existing
4,096-byte cache-entry ceiling still applies). Queries too large for an IPv4 UDP
datagram are forwarded directly over TCP.

## DNS cache

Responses are looked up in the RAM cache only after filtering policy and local
answers. Only upstream responses are inserted. `cache.capacity` configures the
slot count. By default, record TTLs determine expiry.
`cache.min_positive_ttl_seconds` optionally raises the internal lifetime of a
cacheable positive response to at least this many seconds. For example, `300`
reuses a response with a 60-second lifetime for up to 300 seconds, unless evicted.
Hits never renew that lifetime. Returned record TTLs still age from their original
values and saturate at zero; the setting does not extend client caching.

The default `0` respects upstream TTLs. Zero-TTL packets remain non-cacheable,
and NXDOMAIN/NODATA responses (including CNAME chains with SOA) keep their
SOA-derived limits. Longer retention reduces upstream traffic but can serve stale
destinations and delay failover or DNS changes. Configure it in the JSON file,
through `PUT /api/v1/settings` or `PUT /api/v1/config`, or in the UI's Settings
cache section. Changing it clears existing cached responses.

The cache uses direct-mapped slots and exact-sized packet storage. Hash collisions
replace entries. Responses larger than 4096 bytes, queries with EDNS options
other than COOKIE, transaction-authenticated responses, and truncated responses
bypass caching.

Negative responses require an authority SOA and respect its negative-cache TTL.
The cache belongs to one sequential DNS worker, with concurrent management access
guarded by the runtime mutex. Reload preserves it unless upstream servers,
capacity, or minimum positive retention change.

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

## Management API

See [`api.md`](api.md) for the developer and AI-agent API reference, request
schemas, operation lifecycle, error handling, and a complete client workflow.

The embedded server uses `karlseguin/http.zig`, pinned to Zig 0.17-compatible
revision `1bb71ff128a044b1645df91046473c38abbf965c`. The required `api` and `ui`
objects default to enabled. Set both enabled flags to `false` for DNS-only use.
The example enables both and requires a private `api.key` before startup.

Generate a key in the configuration directory:

```sh
(umask 077; openssl rand -hex 32 | tr -d '\n' > examples/api.key)
```

The example already contains the following API section:

```json
"api": {
  "enabled": true,
  "listen": { "address": "127.0.0.1", "port": 8080 },
  "key_file": "api.key",
  "allow_private_sources": false
}
```

`key_file` and `file_root` resolve relative to the configuration directory.
The key is the file's exact contents: no length or character restrictions, and
no whitespace or newline trimming. Empty keys are accepted but insecure; use a
strong random key. HTTP header syntax and server header-size limits still apply,
so use header-safe text without a trailing newline. Comparison is case-sensitive.
On POSIX, group/other permission bits must be zero. The server streams the file
through SHA-256 with a fixed-size buffer, erases temporary plaintext and hash
state, and retains only the digest. Send exactly one `X-API-Key` header.
Missing, duplicate, or incorrect keys return `401`; all keys have administrator
privileges.

API/UI settings, the shared HTTP listener, and key rotation require restart.
Live changes to API/UI settings are rejected before saving or publication.
No built-in TLS or CORS is provided: for remote access, use HTTPS termination
and network access controls. The embedded UI uses the API on the same origin;
do not distribute an administrator key inside a public frontend bundle.

### Resources and actions

All paths below start with `/api/v1` and require authentication, including the
embedded [OpenAPI 3.1 contract](src/api/openapi.json) at `/openapi.json`.

| Method and path | Behavior |
| --- | --- |
| `GET /status` | DNS listener readiness, worker generation, active address, revision, current operation, and saved/active agreement |
| `GET /settings` | Active `dns`, `upstream`, `cache`, and `logging` settings |
| `PUT /settings` | Replace all four settings sections; retain records, rules, sources, and API/UI settings |
| `GET /config` | Canonical active configuration, not the potentially different file contents |
| `PUT /config` | Save and activate a complete configuration |
| `POST /config/validate` | Strict schema/semantic validation without fetching sources or binding sockets |
| `POST /config/reload` | Load and activate the configured file |
| `GET /domains`, `POST /domains` | List or create explicit allow/block rules |
| `GET/PUT/DELETE /domains/{id}` | Read, replace, or delete an explicit rule |
| `GET /records`, `POST /records` | List or create local IN A/AAAA record sets |
| `GET/PUT/DELETE /records/{id}` | Read, replace, or delete a record set |
| `GET /blocklists`, `POST /blocklists` | List or create blocklist source definitions |
| `GET/PUT/DELETE /blocklists/{id}` | Read, replace, or delete a source |
| `POST /blocklists/{id}/refresh` | Refresh one source from its active definition |
| `POST /blocklists/refresh` | Atomically refresh all enabled sources |
| `GET /operations/{id}` | Poll a running or recently completed operation |
| `GET /policy/check?name=example.test&type=A` | Explain exact-name policy; never query upstream |
| `GET /cache` | Cache capacity and occupied slots, including entries not yet reclaimed after expiry |
| `DELETE /cache/entries` | Clear all cached upstream responses |

Status readiness means the DNS listener is running, not that upstream resolvers
are healthy. Policy checks accept `A`, `AAAA`, or a numeric DNS type and assume
class IN. They report the normalized name, decision, reason, and matching
explicit/imported/local conditions. There are no imported allowlists, query
statistics/history, diagnostic-resolution endpoints, or peer endpoints.

Domain request bodies contain `{"domain":"example.test","action":"block"}` or
`"allow"`. Their deterministic IDs are `block:example.test` and
`allow:example.test`. Record request bodies use the same `name`, `type`, `ttl`,
and `addresses` fields as configuration records; IDs are `A:home.test` and
`AAAA:home.test`. URL-encode IDs in paths. PUT can change a rule/record's identity,
but source IDs are immutable. Creating a duplicate identity returns `409`.
Do not include response-only `id` fields in rule/record request bodies.

Collection responses contain `items`, `next_cursor`, and `revision`. `limit`
is 1–100, default 50; `after` accepts the previous page's URL-encoded opaque
cursor. IDs sort lexicographically. Cursors include the revision: after a
completed mutation, a stale cursor returns `409` and the client must restart
its listing. Domain collections additionally accept `action=allow|block` and
an exact, normalized `domain` filter.

### Revisions, operations, and persistence

Read responses expose a quoted global revision in `ETag`. All mutations,
including POST creation, reload, refresh, and cache clearing, require that exact
value in `If-Match`. Missing preconditions return `428`; stale preconditions
return `412`. Validation does not require a revision. One writer operation runs
at a time; another valid-revision mutation returns `409` while it is busy.

Persistent edits, reload, and refresh return `202`, for example:

```json
{"operation":{"id":1,"status":"running","result":null,"error":null},"revision":1}
```

Poll `/operations/1` until `status` is `succeeded` or `failed`. Completion
includes `result.saved`, `result.active`, `result.durability`
(`unchanged`, `durable`, or `uncertain`), the resulting `revision`, and an
optional `resource_id`. Failures include an error name. `202` means accepted,
not successful. The last 64 completed operations are retained in RAM; older
IDs return `404`. Operation IDs and revisions reset on restart.

CRUD and settings writes build a candidate from the active configuration,
validate it, atomically save it, then prepare and publish its runtime changes.
The saved file—not a separate database—makes these changes survive restart.
File saving, source loading, and parsing happen in a background preparation
task. Main remains the only publisher; GETs and operation polling can proceed
while source I/O is pending. Runtime cache/pool inspection or replacement can
wait for an in-progress DNS resolution boundary.

If import or listener activation fails after saving, the old runtime stays
active while the candidate remains on disk. The failed operation reports
`saved: true, active: false`; `/status.saved_matches_active` becomes false.
It is null while an operation is running. The agreement flag tracks operations
performed by this process; it does not detect external file edits. A directory
sync failure reports uncertain durability and does not activate the candidate.
Use `GET /config` to recover the active document, then explicitly PUT it to
restore the saved configuration if desired. Do not assume a failed write left
the file unchanged.

Every completed operation, including failures, advances the management revision;
cache clearing does so immediately and returns `200`. Readiness, source contents,
operation history, and cached DNS packets are not persisted. Stdin commands use
the same writer; `quit`/EOF drain accepted operations before exit.

### Safe source management

Source bodies use the configuration `id`, optional `name`, `enabled`, `source`,
and `format` fields. API-added or content-modified sources receive the persisted
`api_managed: true` marker. Clients cannot clear this marker to regain operator
trust. It ensures restrictions also apply to refresh and startup after restart.
Unchanged operator-provided locations retain their trust; metadata-only edits
do not convert their paths or refetch their contents.

API-managed local sources require `api.file_root`. Their values are relative to
that root, never the configuration directory; absolute paths, traversal,
platform separator tricks, symlinks, and non-regular files are rejected.
API-managed URL sources resolve and validate their destination addresses once
per load, connect to a validated numeric address, and retain the original
hostname for TLS verification and HTTP Host. Redirects are refused.
Private, loopback, link-local, multicast, and reserved addresses are denied
unless `allow_private_sources` explicitly enables private-network access.
The 32 MiB decompressed limit and 30-second deadline apply to all source loads.

Ordinary request bodies are limited to 64 KiB; `/config` and `/config/validate`
permit 1 MiB. Application errors use JSON `error.code` and `error.message`.
Malformed HTTP framing and parser-level limits may return plaintext errors from
http.zig. Oversized or unread rejected bodies close the connection rather than
being drained; clients still transmitting a rejected body may see a reset.

### curl example

The following shell example uses `jq` to read JSON results:

```sh
API=http://127.0.0.1:8080/api/v1
KEY=$(cat examples/api.key)
curl --fail-with-body -H "X-API-Key: $KEY" "$API/status"

REV=$(curl --fail-with-body -sS -H "X-API-Key: $KEY" "$API/status" | jq -r .revision)
OP=$(curl --fail-with-body -sS \
  -H "X-API-Key: $KEY" -H "If-Match: \"$REV\"" \
  -H 'Content-Type: application/json' \
  -d '{"domain":"blocked.test","action":"block"}' "$API/domains" |
  jq -r .operation.id)
curl --fail-with-body -H "X-API-Key: $KEY" "$API/operations/$OP"
```

Repeat the last GET until it completes; obtain a fresh revision before the next
mutation. Use protected curl configuration/header files where exposing a key in
process arguments is unacceptable.
