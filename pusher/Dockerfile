# Steady push relay. Standard library only, so the build needs no module downloads.
# SPDX-License-Identifier: AGPL-3.0-or-later
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /pusher .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /pusher /pusher
EXPOSE 8090
ENTRYPOINT ["/pusher"]
