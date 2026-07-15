# syntax=docker/dockerfile:1.6
# Minimal PHP pod image for M2c-1. FROM alpine:3.21 + apk php84 — the same
# clean-layer pattern containerd-rs unpacks fine (rusternetes-dns, kube-proxy).
# The official php:8.4-apache (Debian /etc/alternatives symlinks) and
# php:8.4-cli-alpine both trip containerd-rs's layer unpacker; this doesn't.
# Runs PHP's built-in server; index.php is provided by a mounted ConfigMap.
FROM alpine:3.21
RUN apk add --no-cache php84
ENTRYPOINT ["php84"]
CMD ["-S", "0.0.0.0:80", "-t", "/var/www/html"]
