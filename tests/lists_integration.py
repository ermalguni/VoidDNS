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
from urllib.parse import quote

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
            "api": {"listen": {"address": "127.0.0.1", "port": api_port}, "key_file": str(key), "file_root": str(base)},
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

        def api(path, method="GET", body=None, etag=None, authenticated=True):
            conn = http.client.HTTPConnection("127.0.0.1", api_port, timeout=5)
            headers = {"X-API-Key": "lists-integration-key"} if authenticated else {}
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

        def browse(id="first", query=""):
            status, _, result = api("/blocklists/" + id + "/domains" + ("?" + query if query else ""))
            assert status == 200, result
            return result

        def matches(*names):
            status, _, result = api("/blocklists/matches", "POST", {"domains": list(names)})
            assert status == 200, result
            return result

        try:
            start()
            assert source("first")["status"]["state"] == "active"
            assert source("missing")["status"]["state"] == "unavailable"
            # Refresh configuration exists only at blocks.refresh, never on a source.
            assert "refresh" not in source("first")
            _, headers, _ = api("/status")
            etag = next(v for k, v in headers.items() if k.lower() == "etag")
            granular = {"id": "granular", "enabled": False, "source": {"kind": "file", "value": "first.txt"}, "format": "domains", "refresh": {"interval_seconds": 60}}
            assert api("/blocklists", "POST", granular, etag)[0] == 400
            invalid_document = json.loads(json.dumps(document))
            invalid_document["blocks"]["lists"][0]["refresh"] = {}
            assert api("/config/validate", "POST", invalid_document)[0] == 400
            assert blocked("first.test") and blocked("common.test")
            assert json.loads(config.read_text())["blocks"]["lists"][2].get("enabled", True)
            assert api("/blocklists/first/domains", authenticated=False)[0] == 401
            assert api("/blocklists/matches", "POST", {"domains": []}, authenticated=False)[0] == 401
            page = browse(query="limit=1")
            assert page["items"] == ["common.test"] and page["next_cursor"]
            assert page["snapshot"]["kind"] == "active" and page["snapshot"]["active"]
            assert browse(query="limit=1&after=" + quote(page["next_cursor"], safe=""))["items"] == ["first.test"]
            assert browse(query="domain=FIRST.test.")["items"] == ["first.test"]
            assert browse(query="prefix=COM")["items"] == ["common.test"]
            assert browse(query="prefix=FIRST.")["items"] == ["first.test"]
            assert browse(query="prefix=first-")["items"] == []
            assert browse(query="domain=absent.test")["items"] == []
            assert browse(query="snapshot=saved")["snapshot"]["active"]
            membership = matches("COMMON.test.", "common.test", "absent.test")
            assert [s["id"] for s in membership["sources"]] == ["first", "second"]
            assert membership["matches"] == [
                {"domain": "common.test", "source_ids": ["first", "second"]},
                {"domain": "absent.test", "source_ids": []},
            ]
            assert matches()["matches"] == [] and matches()["sources"] == []
            assert len(matches(*(["COMMON.test."] * 100))["matches"]) == 1
            with sqlite3.connect(lists) as db:
                db.execute("BEGIN IMMEDIATE")
                db.execute("UPDATE lists SET domain_count=999 WHERE id='first'")
                # The HTTP reader must not use the writer connection or mutex.
                assert browse(query="snapshot=saved")["snapshot"]["domain_count"] == 2
                assert blocked("first.test")
                db.rollback()
            policy = api("/policy/check?name=COMMON.test.")[2]
            assert [s["id"] for s in policy["matching_sources"]] == ["first", "second"]
            assert policy["membership_generation"] == membership["generation"]
            for query in ("limit=0", "limit=101", "limit=-1", "limit=+1", "limit=1&limit=2", "domain=a.test&prefix=a", "domain=*.test", "prefix=a..", "prefix=%C3%A9", "prefix=", "snapshot=other"):
                assert api("/blocklists/first/domains?" + query)[0] == 400, query
            assert api("/blocklists/matches", "POST", {"domains": ["a.test"] * 101})[0] == 400
            assert api("/blocklists/matches", "POST", {"domains": ["*.test"]})[0] == 400
            assert api("/blocklists/matches", "POST", {"domains": ["127.0.0.1"]})[0] == 400
            assert api("/blocklists/matches", "POST", {"domains": [], "extra": True})[0] == 400
            assert api("/blocklists/matches", "POST", {"domains": [123]})[0] == 400
            assert api("/blocklists/matches", "POST", {"domains": ["a" * 64 + ".test"]})[0] == 400
            for query in ("", "snapshot=saved"):
                status, _, error = api("/blocklists/missing/domains?" + query)
                assert status == 404 and error["error"]["message"] == "SnapshotUnavailable"
            for query in ("snapshot=saved", "prefix=first"):
                assert api("/blocklists/first/domains?" + query + "&after=" + quote(page["next_cursor"], safe=""))[0] == 409
            assert api("/blocklists/second/domains?after=" + quote(page["next_cursor"], safe=""))[0] == 409
            first.write_text("common.test\nfirst.test\nnew.test\n")
            mutate("/blocklists/first/refresh")
            assert api("/blocklists/first/domains?after=" + quote(page["next_cursor"], safe=""))[0] == 409
            assert matches("common.test")["generation"] > membership["generation"]
            # A durable commit can precede publication. Saved reads must not
            # claim this content is the active snapshot used by DNS.
            with sqlite3.connect(lists) as db:
                db.execute("DELETE FROM list_domains WHERE list_id='first'")
                db.execute("INSERT INTO domains(name) VALUES('saved-only.test')")
                db.execute("INSERT INTO list_domains(list_id,domain_id,name) SELECT 'first',id,name FROM domains WHERE name='saved-only.test'")
                db.execute("UPDATE lists SET version=lower(hex(randomblob(16))),domain_count=1 WHERE id='first'")
            saved_page = browse(query="snapshot=saved")
            assert saved_page["items"] == ["saved-only.test"] and not saved_page["snapshot"]["active"]
            assert browse(query="snapshot=active")["items"] == ["common.test", "first.test", "new.test"]
            assert matches("saved-only.test")["matches"][0]["source_ids"] == []
            assert blocked("first.test")
            mutate("/blocklists/first/refresh")
            # Disabled definitions retain compatible saved data, never active membership.
            document["blocks"]["lists"][0]["enabled"] = False
            document["allows"] = {"domains": ["common.test"]}
            config.write_text(json.dumps(document))
            mutate("/config/reload")
            disabled = browse()
            assert disabled["snapshot"]["kind"] == "saved" and not disabled["snapshot"]["active"]
            assert disabled["items"] == ["common.test", "first.test", "new.test"]
            assert api("/blocklists/first/domains?snapshot=active")[0] == 404
            policy = api("/policy/check?name=common.test")[2]
            assert policy["reason"] == "explicit_allow" and policy["imported_block"]
            assert [s["id"] for s in policy["matching_sources"]] == ["second"]
            assert matches("common.test")["matches"][0]["source_ids"] == ["second"]
            document["blocks"]["lists"][0]["enabled"] = True
            del document["allows"]
            config.write_text(json.dumps(document))
            mutate("/config/reload")
            document["blocks"]["lists"].append({"id": "matches", "enabled": False, "source": {"kind": "file", "value": "missing.txt"}, "format": "domains"})
            config.write_text(json.dumps(document))
            mutate("/config/reload")
            assert source("matches")["status"]["state"] == "unavailable"
            assert api("/blocklists/matches", "PUT", {})[0] == 428
            mutate("/blocklists/matches", "DELETE")
            assert matches("common.test")["matches"][0]["source_ids"] == ["first", "second"]
            stop()
            # Downgrade the durable fixture to the old schema, then restart with
            # missing sources: migration must retain the last successful content.
            with sqlite3.connect(lists) as db:
                db.execute("PRAGMA foreign_keys=OFF")
                db.execute("ALTER TABLE lists RENAME TO lists_v2")
                db.execute("CREATE TABLE lists(id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind='block'),fingerprint TEXT NOT NULL,last_success_at_ms INTEGER NOT NULL)")
                db.execute("INSERT INTO lists SELECT id,kind,fingerprint,last_success_at_ms FROM lists_v2")
                db.execute("ALTER TABLE list_domains RENAME TO list_domains_v2")
                db.execute("CREATE TABLE list_domains(list_id TEXT NOT NULL REFERENCES lists(id) ON DELETE CASCADE,domain_id INTEGER NOT NULL REFERENCES domains(id),PRIMARY KEY(list_id,domain_id)) WITHOUT ROWID")
                db.execute("INSERT INTO list_domains SELECT list_id,domain_id FROM list_domains_v2")
                db.execute("DROP TABLE list_domains_v2")
                db.execute("DROP TABLE lists_v2")
                db.execute("PRAGMA user_version=1")
            first.unlink()
            second.unlink()
            start()
            with sqlite3.connect(lists) as db:
                assert db.execute("PRAGMA user_version").fetchone()[0] == 2
            health = source("first")["status"]
            assert health["state"] == "degraded" and health["domain_count"] == 3 and health["last_error"]
            assert blocked("first.test") and blocked("second.test")
            degraded = matches("common.test")
            assert [s["status"]["state"] for s in degraded["sources"]] == ["degraded", "degraded"]
            assert browse()["snapshot"]["active"] and browse(query="snapshot=saved")["snapshot"]["active"]
            mutate("/blocklists/refresh")
            assert blocked("common.test")
            first.write_text("")
            mutate("/blocklists/first/refresh")
            assert source("first")["status"]["domain_count"] == 0
            assert browse()["items"] == [] and browse()["snapshot"]["domain_count"] == 0
            assert matches("first.test")["matches"][0]["source_ids"] == []
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
            assert api("/blocklists/first/domains?snapshot=saved")[0] == 404
            stop()
            with sqlite3.connect(lists) as db:
                assert db.execute("SELECT count(*) FROM lists WHERE id='second'").fetchone()[0] == 0
            assert lists.stat().st_mode & 0o077 == 0
            # Exercise real timer admission, disabled snapshots, backoff and recovery.
            first.write_text("scheduled-old.test\n")
            saved["blocks"] = {
                "refresh": {"interval_seconds": 2, "jitter_percent": 0, "retry_initial_seconds": 2, "retry_max_seconds": 8},
                "lists": [{"id": "first", "enabled": False, "source": {"kind": "file", "value": "first.txt"}, "format": "domains"}],
            }
            config.write_text(json.dumps(saved))
            start()

            def await_source(predicate):
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    current = source("first")["status"]
                    if predicate(current):
                        return current
                    time.sleep(0.05)
                raise AssertionError(("scheduled refresh timeout", current))

            initial = source("first")["status"]
            assert initial["snapshot_domain_count"] == 1 and initial["active_domain_count"] == 0
            assert initial["next_refresh_at_ms"] and initial["last_attempt_at_ms"]
            first.write_text("scheduled-new.test\nshared.test\n")
            updated = await_source(lambda s: s["snapshot_domain_count"] == 2)
            assert updated["last_success_at_ms"] > initial["last_success_at_ms"]
            assert not imported("scheduled-new.test")
            assert browse()["items"] == ["scheduled-new.test", "shared.test"]
            assert matches("scheduled-new.test")["sources"] == []
            first.write_text("||invalid.test^\n")
            failed = await_source(lambda s: s["consecutive_failures"] >= 1)
            assert failed["state"] == "degraded" and failed["last_success_at_ms"] == updated["last_success_at_ms"]
            assert failed["next_refresh_at_ms"] > failed["last_completed_at_ms"]
            assert browse()["items"] == ["scheduled-new.test", "shared.test"]
            first.write_text("recovered.test\n")
            recovered = await_source(lambda s: s["consecutive_failures"] == 0 and s["last_success_at_ms"] > updated["last_success_at_ms"])
            assert recovered["snapshot_domain_count"] == 1 and not imported("recovered.test")
            # Manual-only stops timer refreshes without disabling manual refresh.
            saved["blocks"]["refresh"]["enabled"] = False
            config.write_text(json.dumps(saved))
            mutate("/config/reload")
            assert source("first")["status"]["next_refresh_at_ms"] is None
            first.write_text("manual-only.test\n")
            time.sleep(3)
            assert browse()["items"] == ["recovered.test"]
            mutate("/blocklists/first/refresh")
            assert browse()["items"] == ["manual-only.test"] and not imported("manual-only.test")
            # Re-enable policy participation; publication exposes the complete set.
            saved["blocks"]["lists"][0]["enabled"] = True
            config.write_text(json.dumps(saved))
            mutate("/config/reload")
            assert blocked("manual-only.test")
            saved["blocks"]["refresh"]["enabled"] = True
            config.write_text(json.dumps(saved))
            mutate("/config/reload")
            first.write_text("enabled-timer.test\n")
            await_source(lambda s: s["active_domain_count"] == 1 and s["last_success_at_ms"] > recovered["last_success_at_ms"] and imported("enabled-timer.test"))
            assert blocked("enabled-timer.test") and not imported("manual-only.test")
            stop()
            print("List integration passed: persistence, restart fallback, health, overlap, empty replacement, deletion, definition isolation, and private database.")
        finally:
            if proc and proc.poll() is None:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    run()
