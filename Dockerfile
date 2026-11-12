# syntax=docker/dockerfile:1
# Binaries are built and smoke-tested by the Linux packaging workflow.
FROM alpine:3.22
RUN apk add --no-cache ca-certificates

ARG TARGETARCH
ARG TARGETVARIANT
ARG BINARY_PATH=container-bin/${TARGETARCH}${TARGETVARIANT}/VoidDNS
COPY --chmod=755 ${BINARY_PATH} /usr/local/bin/VoidDNS
COPY LICENSE /usr/share/licenses/voiddns/LICENSE

WORKDIR /config
USER 65532:65532
EXPOSE 5353/udp 5353/tcp 8080/tcp
ENTRYPOINT ["/usr/local/bin/VoidDNS"]
CMD ["--config", "/config/voiddns.json"]
