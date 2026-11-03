# Steady push relay. Standard library only, so the build needs no module downloads.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Go 1.27: each Go release gets security fixes until the second one after it comes out
FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /pusher .

# debian13: the debian12 images are no longer updated (their CA certificates included)
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /pusher /pusher
EXPOSE 8090
ENTRYPOINT ["/pusher"]
