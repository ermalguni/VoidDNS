"""Exercise durable blocklist snapshots through real DNS and management HTTP."""
import http.client
import json
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time

BINARY = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path("zig-out/bin/VoidDNS")).resolve()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run():
    with tempfile.TemporaryDirectory(prefix="voiddns-lists-") as directory:
        base = Path(directory)
        key = base / "api.key"
        key.write_text("lists-integration-key")
        key.chmod(0o600)
        first, second = base / "first.txt", base / "second.txt"
        first.write_text("common.test\nfirst.test\n")
        second.write_text("common.test\nsecond.test\n")
        dns_port, api_port = free_port(), free_port()
        document = {
            "schema_version": 2,
            "api": {"listen": {"address": "127.0.0.1", "port": api_port}, "key_file": str(key)},
            "ui": {},
            "dns": {"listen": {"address": "127.0.0.1", "port": dns_port}},
            "upstream": {"servers": [{"address": "127.0.0.1", "port": free_port()}], "timeout_ms": 50},
            "blocks": {"lists": [
                {"id": "first", "source": {"kind": "file", "value": "first.txt"}, "format": "domains"},
                {"id": "second", "source": {"kind": "file", "value": "second.txt"}, "format": "domains"},
                {"id": "missing", "source": {"kind": "file", "value": "missing.txt"}, "format": "domains"},
            ]},
        }
        config = base / "config.json"
        config.write_text(json.dumps(document))
        database, lists = base / "history.sqlite3", base / "lists.sqlite3"
        proc = None

        def api(path, method="GET", body=None, etag=None):
            conn = http.client.HTTPConnection("127.0.0.1", api_port, timeout=5)
            headers = {"X-API-Key": "lists-integration-key"}
            if etag:
                headers["If-Match"] = etag
            if body is not None:
                headers["Content-Type"] = "application/json"
            conn.request(method, "/api/v1" + path, json.dumps(body) if body is not None else None, headers)
            response = conn.getresponse()
            result = response.status, dict(response.getheaders()), json.loads(response.read())
            conn.close()
            return result

        def start():
            nonlocal proc
            with open(base / "stderr.log", "ab") as log:
                proc = subprocess.Popen([str(BINARY), "--config", str(config), "--database", str(database), "--lists-database", str(lists), "--control-stdin"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=log)
            for _ in range(200):
                assert proc.poll() is None, (base / "stderr.log").read_text()
                try:
                    if api("/status")[0] == 200:
                        return
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.025)
            raise AssertionError("startup timeout")

        def stop():
            proc.communicate(b"quit\n", timeout=15)
            assert proc.returncode == 0, (base / "stderr.log").read_text()

        def source(id):
            status, _, data = api("/blocklists/" + id)
            assert status == 200, data
            return data

        def mutate(path, method="POST", body=None):
            _, headers, _ = api("/status")
            etag = next(v for k, v in headers.items() if k.lower() == "etag")
            status, _, operation = api(path, method, body, etag)
            assert status == 202, operation
            for _ in range(200):
                _, _, result = api("/operations/" + str(operation["operation"]["id"]))
                if result["status"] != "running":
                    assert result["status"] == "succeeded", result
                    return
                time.sleep(0.025)
            raise AssertionError("operation timeout")

        def blocked(name):
            wire = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
            packet = struct.pack("!6H", 321, 0x100, 1, 0, 0, 0) + wire + struct.pack("!HH", 1, 1)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.sendto(packet, ("127.0.0.1", dns_port))
                response = sock.recv(65535)
            return struct.unpack("!H", response[6:8])[0] == 1 and response[-4:] == b"\0\0\0\0"

        def imported(name):
            status, _, result = api("/policy/check?name=" + name)
            assert status == 200, result
            return result["imported_block"]

        try:
            start()
            assert source("first")["status"]["state"] == "active"
            assert source("missing")["status"]["state"] == "unavailable"
            assert blocked("first.test") and blocked("common.test")
            assert json.loads(config.read_text())["blocks"]["lists"][2].get("enabled", True)
            stop()
            first.unlink()
            second.unlink()
            start()
            health = source("first")["status"]
            assert health["state"] == "degraded" and health["domain_count"] == 2 and health["last_error"]
            assert blocked("first.test") and blocked("second.test")
            mutate("/blocklists/refresh")
            assert blocked("common.test")
            first.write_text("")
            mutate("/blocklists/first/refresh")
            assert source("first")["status"]["domain_count"] == 0
            assert not imported("first.test") and blocked("common.test")
            mutate("/blocklists/second", "DELETE")
            assert not imported("common.test")
            # Recreate successful content, then ensure a changed definition cannot reuse it.
            first.write_text("restored.test\n")
            mutate("/blocklists/first/refresh")
            assert blocked("restored.test")
            stop()
            saved = json.loads(config.read_text())
            saved["blocks"]["lists"][0]["source"]["value"] = "different-missing.txt"
            config.write_text(json.dumps(saved))
            start()
            assert source("first")["status"]["state"] == "unavailable"
            assert not imported("restored.test")
            stop()
            with sqlite3.connect(lists) as db:
                assert db.execute("SELECT count(*) FROM lists WHERE id='second'").fetchone()[0] == 0
            assert lists.stat().st_mode & 0o077 == 0
            print("List integration passed: persistence, restart fallback, health, overlap, empty replacement, deletion, definition isolation, and private database.")
        finally:
            if proc and proc.poll() is None:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    run()
