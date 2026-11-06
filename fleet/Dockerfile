# Steady fleet view. Standard library only, so the build needs no module downloads.
# Built from the top of the repository (compose.yml), so it can take VERSION and the code of the
# community sign-in bridge for this release (deploy/code-of.sh): it checks that the bridge runs
# exactly that, and shows which release it runs itself.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Go 1.27: each Go release gets security fixes until the second one after it comes out
FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY fleet/go.mod ./
COPY fleet/*.go ./
COPY fleet/web ./web
COPY community/signin/go.mod /bridge/
COPY community/signin/*.go /bridge/
COPY community/signin/web /bridge/web
COPY VERSION deploy/code-of.sh /meta/
RUN CGO_ENABLED=0 go test ./... && \
    v="$(tr -cd '0-9.' < /meta/VERSION)" && c="$(sh /meta/code-of.sh /src)" && b="$(sh /meta/code-of.sh /bridge)" && \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.buildVersion=$v -X main.buildCode=$c -X main.bridgeCode=$b" -o /fleet .

# debian13: the debian12 images are no longer updated (their CA certificates included)
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /fleet /fleet
EXPOSE 8080
ENTRYPOINT ["/fleet"]
CMD ["serve"]
