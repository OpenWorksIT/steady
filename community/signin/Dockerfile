# Steady community sign-in bridge. Standard library only, so the build needs no module downloads.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Go 1.27: each Go release gets security fixes until the second one after it comes out
FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
COPY web ./web
RUN CGO_ENABLED=0 go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /signin .

# debian13: the debian12 images are no longer updated (their CA certificates included)
FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /signin /signin
EXPOSE 8080
ENTRYPOINT ["/signin"]
CMD ["serve"]
