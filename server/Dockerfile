# Steady server: PocketBase with Steady's migrations and hooks.
# SPDX-License-Identifier: AGPL-3.0-or-later
FROM alpine:3.24.3

ARG PB_VERSION=0.40.6
ARG TARGETARCH=amd64
# The release's own checksums.txt comes from the same place as the zip, so it only catches a
# broken download. These are pinned here (checked against that file and a copy downloaded
# separately); a new PB_VERSION needs new ones. PocketBase said 0.40.6 is likely its last
# release on GitHub (later ones come from its author's own site): a newer version needs
# this download address checked too, not only new sums.
ARG PB_SHA256_amd64=0e1f609158ed945f809f8a02ae012aa0427129c66ebb63c1aee76f2c0309373f
ARG PB_SHA256_arm64=d22c66ceb67ca92b7d767f36d826e848a276bcfa3c197ead20bf87c42208984f

RUN apk add --no-cache ca-certificates tzdata unzip wget sqlite curl \
 && cd /tmp \
 && wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" \
 && want="$(eval echo "\${PB_SHA256_${TARGETARCH}:-}")" && [ -n "$want" ] \
 && echo "$want  pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" | sha256sum -c - \
 && unzip -q "pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" pocketbase -d /pb \
 && rm -f /tmp/*.zip \
 && adduser -D -H -u 10001 steady \
 && mkdir -p /pb/pb_data && chown steady /pb/pb_data

COPY pb_migrations /pb/pb_migrations
COPY pb_hooks /pb/pb_hooks

USER steady
EXPOSE 8090
VOLUME ["/pb/pb_data"]
CMD ["/pb/pocketbase", "serve", "--http=0.0.0.0:8090", "--dir=/pb/pb_data", \
     "--hooksDir=/pb/pb_hooks", "--migrationsDir=/pb/pb_migrations", "--automigrate=false"]
