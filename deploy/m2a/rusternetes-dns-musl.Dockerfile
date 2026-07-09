# syntax=docker/dockerfile:1.6
# Musl-static rusternetes-dns for the M2c kube-dns Deployment (runs as a pod,
# not on /boot). Mirrors kube-proxy-musl.Dockerfile — COPY crates wholesale so
# there is no stale per-crate COPY list (rusternetes/dns.Dockerfile breaks on a
# removed netstack crate). Arg-free ENTRYPOINT => the binary uses in-cluster
# config (SA token + KUBERNETES_SERVICE_HOST) and serves cluster.local on :53.
#
# Build context is the parent of rusternetes:
#   docker build -f mikronetes/deploy/m2a/rusternetes-dns-musl.Dockerfile \
#     -t rusternetes-dns:m2c /home/jones/PhpstormProjects

FROM rust:1.95-alpine AS builder

ARG SCCACHE_VERSION=v0.8.2
RUN apk add --no-cache \
    protobuf \
    protobuf-dev \
    cmake \
    build-base \
    perl \
    curl \
    git \
 && curl -fsSL "https://github.com/mozilla/sccache/releases/download/${SCCACHE_VERSION}/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xz -C /tmp \
 && install -m 0755 "/tmp/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache" /usr/local/bin/sccache \
 && rm -rf "/tmp/sccache-${SCCACHE_VERSION}-x86_64-unknown-linux-musl"

ENV RUSTC_WRAPPER=sccache \
    SCCACHE_DIR=/sccache \
    SCCACHE_CACHE_SIZE=20G \
    SCCACHE_IDLE_TIMEOUT=0 \
    CARGO_INCREMENTAL=0 \
    LIBZ_SYS_STATIC=1

WORKDIR /build
COPY rusternetes/rhino ./rusternetes/rhino
COPY rusternetes/Cargo.toml rusternetes/Cargo.lock* ./rusternetes/
COPY rusternetes/crates ./rusternetes/crates

WORKDIR /build/rusternetes
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/build/rusternetes/target \
    --mount=type=cache,target=/sccache,id=sccache-rusternetes-musl,sharing=locked \
    cargo build --profile release-fast --features sqlite -p rusternetes-dns && \
    mkdir -p /out && cp target/release-fast/rusternetes-dns /out/rusternetes-dns && \
    sccache --show-stats

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY --from=builder /out/rusternetes-dns /app/rusternetes-dns
ENTRYPOINT ["/app/rusternetes-dns"]
