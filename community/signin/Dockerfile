# Steady community sign-in bridge. Standard library only, so the build needs no module downloads.
# Built from the top of the repository (compose.yml), so it can take VERSION and say which code it
# runs (GET /version, deploy/code-of.sh), for the fleet view to check against its own release.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Go 1.27: each Go release gets security fixes until the second one after it comes out
FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY community/signin/go.mod ./
COPY community/signin/*.go ./
COPY community/signin/web ./web
COPY VERSION deploy/code-of.sh /meta/
RUN CGO_ENABLED=0 go test ./... && \
    v="$(tr -cd '0-9.' < /meta/VERSION)" && c="$(sh /meta/code-of.sh /src)" && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.buildVersion=$v -X main.buildCode=$c" -o /signin .

# debian13: the debian12 images are no longer updated (their CA certificates included)
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /signin /signin
EXPOSE 8080
ENTRYPOINT ["/signin"]
CMD ["serve"]
