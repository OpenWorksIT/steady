# Steady server: PocketBase with Steady's migrations and hooks.
# SPDX-License-Identifier: AGPL-3.0-or-later
FROM alpine:3.22

ARG PB_VERSION=0.40.5
ARG TARGETARCH=amd64

RUN apk add --no-cache ca-certificates tzdata unzip wget sqlite curl \
 && cd /tmp \
 && wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" \
 && wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/checksums.txt" \
 && grep " pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip$" checksums.txt | sha256sum -c - \
 && unzip -q "pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" pocketbase -d /pb \
 && rm -f /tmp/*.zip /tmp/checksums.txt \
 && adduser -D -H -u 10001 steady \
 && mkdir -p /pb/pb_data && chown steady /pb/pb_data

COPY pb_migrations /pb/pb_migrations
COPY pb_hooks /pb/pb_hooks

USER steady
EXPOSE 8090
VOLUME ["/pb/pb_data"]
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8090", "--dir=/pb/pb_data", \
     "--hooksDir=/pb/pb_hooks", "--migrationsDir=/pb/pb_migrations", "--automigrate=false"]
