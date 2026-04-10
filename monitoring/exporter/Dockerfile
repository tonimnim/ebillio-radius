# syntax=docker/dockerfile:1.7
#
# Multi-stage build for bvantagelimited/freeradius_exporter.
#
# Why we build from source: upstream publishes signed binary release
# artifacts on GitHub but does NOT publish a container image to Docker Hub
# or ghcr.io. Rather than depend on a third-party rebuilder of unknown
# provenance, we compile the exporter ourselves from the pinned upstream
# tag inside a hermetic builder stage and ship a static binary in a
# distroless runtime.
#
# Pinned versions:
#   - Go toolchain:    golang:1.23-alpine3.20  (Go >=1.21 required by go.mod)
#   - Exporter source: bvantagelimited/freeradius_exporter@0.1.9
#   - Runtime base:    gcr.io/distroless/static-debian12:nonroot
#
# Build:    docker compose build freeradius_exporter
# Expected: ~25MB final image, ~10MB binary, first build ~60s.

# ---------- Stage 1: builder ------------------------------------------------
FROM golang:1.23-alpine3.20 AS builder

ARG EXPORTER_VERSION=0.1.9

RUN apk add --no-cache git ca-certificates

WORKDIR /src
RUN git clone --depth 1 --branch ${EXPORTER_VERSION} \
        https://github.com/bvantagelimited/freeradius_exporter.git . \
 && go mod download

# Static, stripped binary so it runs on distroless (no libc, no shell).
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} \
    go build \
        -trimpath \
        -ldflags="-s -w -X main.version=${EXPORTER_VERSION}" \
        -o /freeradius_exporter \
        .

# ---------- Stage 2: runtime ------------------------------------------------
# distroless/static is ~2MB and contains only ca-certificates, /etc/passwd
# (with a `nonroot` user, uid 65532), tzdata, and /tmp. No shell, no
# package manager, no libc. The exporter is a static Go binary so it has
# everything it needs.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /freeradius_exporter /freeradius_exporter

USER nonroot:nonroot
EXPOSE 9812

# No HEALTHCHECK: distroless has no shell, and the exporter has no
# built-in health endpoint we can probe without `wget`/`curl`. The
# upstream FreeRADIUS container is the source of truth for "is RADIUS
# alive"; this exporter is best-effort scraping.

ENTRYPOINT ["/freeradius_exporter"]
