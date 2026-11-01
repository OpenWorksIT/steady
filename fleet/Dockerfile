# Steady fleet view. Standard library only, so the build needs no module downloads.
# SPDX-License-Identifier: AGPL-3.0-or-later
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /fleet .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /fleet /fleet
EXPOSE 8080
ENTRYPOINT ["/fleet"]
CMD ["serve"]
