#!/usr/bin/env bash
# Exercise the embedded UI, API-only mode, and DNS-only mode in release images.
set -euo pipefail
image=${1:?image required}
platform=${2:?platform required}
config=$(mktemp -d)
container=
cleanup() {
    result=$?
    if [[ "$result" != 0 && -n "$container" ]]; then docker logs "$container"; fi
    if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null; fi
    rm -rf "$config"
}
trap cleanup EXIT
chmod 755 "$config"
printf 'smoke-key' > "$config/api.key"
chmod 600 "$config/api.key"
docker run --rm --platform "$platform" --user 0 --entrypoint chown \
    --mount "type=bind,src=$config,dst=/config" "$image" 65532:65532 /config/api.key
for mode in full api dns invalid; do
    api=true; ui=true; key_file=api.key
    case "$mode" in
        api) ui=false ;;
        dns) api=false; ui=false; key_file=missing.key ;;
        invalid) api=false ;;
    esac
    cat > "$config/voiddns.json" <<EOF
{"schema_version":2,"dns":{"listen":{"address":"0.0.0.0","port":5353}},"upstream":{"servers":[{"address":"127.0.0.1","port":9}]},"api":{"enabled":$api,"listen":{"address":"0.0.0.0","port":8080},"key_file":"$key_file"},"ui":{"enabled":$ui},"records":[{"name":"smoke.test","type":"A","addresses":["192.0.2.42"]}]}
EOF
    chmod 644 "$config/voiddns.json"
    container=$(docker run -d --platform "$platform" --cap-drop ALL --read-only --tmpfs /tmp \
        -p 127.0.0.1::8080 -p 127.0.0.1::5353/udp \
        --mount "type=bind,src=$config,dst=/config,readonly" "$image" \
        --config /config/voiddns.json --database /tmp/voiddns.sqlite3)
    if [[ "$mode" == invalid ]]; then
        code=$(docker wait "$container")
        [[ "$code" != 0 ]]
    else
        dns=$(docker port "$container" 5353/udp)
        # A real local DNS response also proves the worker starts in DNS-only mode.
        node --input-type=module - "$dns" <<'JS'
import dgram from 'node:dgram';
const socket = dgram.createSocket('udp4');
const query = Buffer.from('00010100000100000000000005736d6f6b6504746573740000010001', 'hex');
const port = Number(process.argv[2].split(':').pop());
const deadline = setTimeout(() => { clearInterval(retry); socket.close(); console.error('DNS response timeout'); process.exitCode = 1; }, 20000);
const retry = setInterval(() => socket.send(query, port, '127.0.0.1'), 250);
socket.on('message', message => {
    clearInterval(retry); clearTimeout(deadline); socket.close();
    if (message.readUInt16BE(0) !== 1 || message.readUInt16BE(6) !== 1 || message.subarray(-4).toString('hex') !== 'c000022a') throw new Error('Unexpected local DNS answer');
});
socket.send(query, port, '127.0.0.1');
JS
        address=$(docker port "$container" 8080/tcp)
        origin="http://$address"
        if [[ "$mode" == dns ]]; then
            if curl --fail --silent --max-time 3 "$origin/" -o /dev/null; then
                echo 'DNS-only mode unexpectedly serves HTTP'; exit 1
            fi
        else
            curl --fail --silent --show-error --retry 20 --retry-delay 1 --retry-all-errors \
                -H 'X-API-Key: smoke-key' "$origin/api/v1/status" -o "$config/status.json"
            node -e 'const s = JSON.parse(require("fs").readFileSync(process.argv[1])); if (s.dns.ready !== true) process.exit(1)' "$config/status.json"
            code=$(curl --silent --show-error -o "$config/reply" -w '%{http_code}' "$origin/api/v1/status")
            [[ "$code" == 401 ]]
            if [[ "$mode" == full ]]; then
                curl --fail --silent --show-error "$origin/" -o "$config/index.html"
                curl --fail --silent --show-error "$origin/records" -o "$config/route.html"
                cmp "$config/index.html" "$config/route.html"
                node --input-type=module - "$origin" "$config/index.html" <<'JS'
import { readFileSync } from 'node:fs';
const asset = readFileSync(process.argv[3], 'utf8').match(/src="([^"]+\.js)"/)[1];
const response = await fetch(process.argv[2] + asset);
if (!response.ok || !response.headers.get('content-type')?.includes('javascript') || !response.headers.get('cache-control')?.includes('immutable')) throw new Error('Embedded JavaScript asset is not served correctly');
const head = await fetch(process.argv[2] + asset, { method: 'HEAD' });
if (!head.ok || (await head.arrayBuffer()).byteLength !== 0) throw new Error('Invalid asset HEAD response');
JS
                code=$(curl --silent --show-error -o "$config/reply" -w '%{http_code}' "$origin/assets/missing.js")
                [[ "$code" == 404 ]]
            else
                code=$(curl --silent --show-error -o "$config/reply" -w '%{http_code}' "$origin/")
                [[ "$code" == 404 ]]
            fi
        fi
    fi
    docker rm -f "$container" >/dev/null
    container=
    printf 'Embedded UI smoke passed: %s mode=%s\n' "$platform" "$mode"
done
