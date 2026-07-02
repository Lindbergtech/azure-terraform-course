# syntax=docker/dockerfile:1.7
# Multi-stage build → static binary in FROM scratch. Target image <20MB.

FROM golang:1.22-alpine AS build
WORKDIR /src

# Cached dep layer.
COPY go.mod go.sum ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/urlshortener ./...

# Final image: scratch + ca-certificates (pgx needs CA roots for TLS to Azure
# Postgres). nonroot uid/gid baked in via /etc/passwd from the build stage.
FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/urlshortener /urlshortener
EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/urlshortener"]
