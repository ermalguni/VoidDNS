# syntax=docker/dockerfile:1
# Build ui/dist with npm ci && npm run build in ui/ before building this image.
FROM caddy:2.10.2-alpine
# Caddy's base image grants low-port binding; this image uses an unprivileged port.
# Remove the file capability so execution works with --cap-drop ALL.
RUN setcap -r /usr/bin/caddy
COPY ui/dist/ /usr/share/voiddns/ui/
COPY ui/Caddyfile.container /etc/caddy/Caddyfile
COPY LICENSE /usr/share/licenses/voiddns/LICENSE
ENV XDG_CONFIG_HOME=/tmp/caddy/config XDG_DATA_HOME=/tmp/caddy/data
USER 65532:65532
EXPOSE 8081/tcp
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
