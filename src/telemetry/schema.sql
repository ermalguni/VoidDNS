BEGIN IMMEDIATE;
CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY,
    ip_address TEXT NOT NULL UNIQUE,
    name TEXT DEFAULT NULL,
    first_seen_at_ms INTEGER NOT NULL,
    last_seen_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE IF NOT EXISTS requests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    received_at_ms INTEGER NOT NULL,
    domain TEXT,
    query_type INTEGER CHECK(query_type BETWEEN 0 AND 65535),
    query_class INTEGER CHECK(query_class BETWEEN 0 AND 65535),
    transport TEXT NOT NULL CHECK(transport IN ('udp','tcp')),
    resolution TEXT NOT NULL CHECK(resolution IN ('blocked','cached','forwarded','local','rejected')),
    rcode INTEGER CHECK(rcode BETWEEN 0 AND 4095),
    duration_us INTEGER NOT NULL CHECK(duration_us >= 0),
    error TEXT
) STRICT;
CREATE INDEX IF NOT EXISTS requests_client_time ON requests(client_id,received_at_ms,id);
CREATE INDEX IF NOT EXISTS requests_time ON requests(received_at_ms,id);
PRAGMA user_version=1;
COMMIT;
