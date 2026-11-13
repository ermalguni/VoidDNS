"""Run after `zig build`: python3 tests/telemetry_integration.py.

Uses temporary configuration/database files and localhost sockets only.
"""
import http.client
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
BINARY = (Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "zig-out/bin/VoidDNS").resolve()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def query(name):
    wire = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
    return struct.pack("!6H", 123, 0x100, 1, 0, 0, 0) + wire + struct.pack("!HH", 1, 1)


def run():
    with tempfile.TemporaryDirectory(prefix="voiddns-telemetry-") as directory:
        base = Path(directory)
        key = base / "api.key"
        key.write_text("integration-key")
        key.chmod(0o600)
        dns_port, api_port = free_port(), free_port()
        upstream = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        upstream.bind(("127.0.0.1", 0))
        upstream.settimeout(0.1)
        stop = threading.Event()

        def serve_upstream():
            while not stop.is_set():
                try:
                    packet, address = upstream.recvfrom(65535)
                except socket.timeout:
                    continue
                answer = packet[:2] + struct.pack("!5H", 0x8180, 1, 1, 0, 0) + packet[12:]
                answer += b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + b"\xc0\x00\x02\x0a"
                upstream.sendto(answer, address)

        thread = threading.Thread(target=serve_upstream)
        thread.start()
        config = base / "config.json"
        config.write_text(json.dumps({
            "schema_version": 2,
            "api": {"listen": {"address": "127.0.0.1", "port": api_port}, "key_file": str(key)},
            "ui": {},
            "dns": {"listen": {"address": "127.0.0.1", "port": dns_port}},
            "upstream": {"servers": [{"address": "127.0.0.1", "port": upstream.getsockname()[1]}]},
            "blocks": {"domains": ["blocked.test"]},
            "records": [{"name": "local.test", "type": "A", "addresses": ["192.0.2.11"]}],
        }))
        database = base / "nested" / "history.sqlite3"

        def api(path, method="GET", body=None, etag=None, auth=True):
            conn = http.client.HTTPConnection("127.0.0.1", api_port, timeout=5)
            headers = {"X-API-Key": "integration-key"} if auth else {}
            if etag:
                headers["If-Match"] = etag
            if body is not None:
                headers["Content-Type"] = "application/json"
            conn.request(method, "/api/v1" + path, json.dumps(body) if body is not None else None, headers)
            response = conn.getresponse()
            data = response.read()
            result = response.status, dict(response.getheaders()), json.loads(data)
            conn.close()
            return result

        def start():
            log = open(base / "stderr.log", "ab")
            proc = subprocess.Popen([str(BINARY), "--config", str(config), "--database", str(database), "--control-stdin"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
            log.close()
            for _ in range(100):
                if proc.poll() is not None:
                    raise AssertionError((base / "stderr.log").read_text())
                try:
                    if api("/status")[0] == 200:
                        return proc
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.05)
            proc.kill()
            raise AssertionError("startup timeout")

        def shutdown(proc):
            if proc.poll() is None:
                proc.communicate(b"quit\n", timeout=10)
            assert proc.returncode == 0, (base / "stderr.log").read_text()

        proc = None
        try:
            proc = start()
            assert api("/metrics/summary", auth=False)[0] == 401
            assert api("/requests", auth=False)[0] == 401
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(3)
                for name in ["blocked.test", "local.test", "upstream.test", "upstream.test"]:
                    sock.sendto(query(name), ("127.0.0.1", dns_port))
                    assert len(sock.recv(65535)) >= 12
            with socket.create_connection(("127.0.0.1", dns_port), timeout=3) as sock:
                packet = query("upstream.test")
                sock.sendall(struct.pack("!H", len(packet)) + packet)
                prefix = sock.recv(2)
                size = struct.unpack("!H", prefix)[0]
                response = b""
                while len(response) < size:
                    response += sock.recv(size - len(response))
            for _ in range(100):
                summary = api("/metrics/summary")[2]["data"]
                if summary["total"] == 5:
                    break
                time.sleep(0.05)
            assert {k: summary[k] for k in ["total", "blocked", "cached", "forwarded", "local", "active_clients"]} == {
                "total": 5, "blocked": 1, "cached": 2, "forwarded": 1, "local": 1, "active_clients": 1,
            }, summary
            clients = api("/clients")[2]["data"]
            assert clients[0]["ip_address"] == "127.0.0.1", clients
            revision = api("/status")[1]["ETag"]
            assert api("/clients/1", "PATCH", {"name": "Test workstation"})[0] == 428
            renamed = api("/clients/1", "PATCH", {"name": "Test workstation"}, revision)
            assert renamed[0] == 200, renamed
            assert api("/clients/1", "PATCH", {"name": "Stale"}, revision)[0] == 412
            first = api("/requests?limit=2")[2]
            second = api("/requests?limit=2&after=" + first["next"])[2]
            assert not ({r["id"] for r in first["data"]} & {r["id"] for r in second["data"]})
            assert any(r["transport"] == "tcp" for r in api("/requests")[2]["data"])
            for endpoint in ["/metrics/timeseries", "/metrics/domains?resolution=blocked", "/metrics/clients", "/metrics/health"]:
                assert api(endpoint)[0] == 200, endpoint
            assert api("/metrics/summary?limit=101")[0] == 400
            # Hold the SQLite writer lock beyond its busy timeout. DNS and
            # independent read connections must remain available.
            with sqlite3.connect(database) as lock:
                lock.execute("BEGIN IMMEDIATE")
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.settimeout(1)
                    sock.sendto(query("local.test"), ("127.0.0.1", dns_port))
                    assert len(sock.recv(65535)) >= 12
                for _ in range(80):
                    health = api("/metrics/health")[2]
                    if not health["writer_healthy"]:
                        break
                    time.sleep(0.05)
                assert not health["writer_healthy"], health
                assert health["dropped_events_since_start"] >= 1
                assert api("/metrics/summary")[0] == 200
                assert api("/status")[0] == 200
                lock.rollback()
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.sendto(query("local.test"), ("127.0.0.1", dns_port))
                sock.recv(65535)
            for _ in range(80):
                if api("/metrics/health")[2]["writer_healthy"]:
                    break
                time.sleep(0.05)
            assert api("/metrics/health")[2]["writer_healthy"]
            shutdown(proc)
            proc = None
            assert os.stat(database).st_mode & 0o077 == 0
            with sqlite3.connect(database) as db:
                assert db.execute("SELECT count(*) FROM requests").fetchone()[0] == 6
                db.execute("UPDATE requests SET received_at_ms=?", (int(time.time() * 1000) - 8 * 86400000,))
            proc = start()
            assert api("/metrics/summary")[2]["data"]["total"] == 0
            assert api("/clients/1")[2]["name"] == "Test workstation"
            latencies = []
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                started = time.perf_counter()
                for _ in range(200):
                    before = time.perf_counter()
                    sock.sendto(query("local.test"), ("127.0.0.1", dns_port))
                    sock.recv(65535)
                    latencies.append((time.perf_counter() - before) * 1000)
                elapsed = time.perf_counter() - started
            latencies.sort()
            print(f"Local UDP smoke measurement (200 sequential requests): {200 / elapsed:.0f} requests/s, p50 {latencies[100]:.3f} ms, p95 {latencies[190]:.3f} ms. Not a comparative benchmark.")
            status_path = Path(f"/proc/{proc.pid}/status")
            if status_path.exists():
                rss = next(line for line in status_path.read_text().splitlines() if line.startswith("VmRSS:"))
                print(f"Server resident memory after smoke workload: {rss.split(':', 1)[1].strip()}.")
            shutdown(proc)
            proc = None
            with sqlite3.connect(database) as db:
                assert db.execute("SELECT count(*) FROM requests WHERE received_at_ms < ?", (int(time.time() * 1000) - 7 * 86400000,)).fetchone()[0] == 0
            print("Telemetry integration passed: UDP/TCP attribution, outcomes, authentication, revision conflicts, pagination, persistence, retention, writer failure/recovery, and private file creation.")
        finally:
            if proc and proc.poll() is None:
                proc.kill()
                proc.wait()
            stop.set()
            thread.join(timeout=2)
            upstream.close()


if __name__ == "__main__":
    run()
