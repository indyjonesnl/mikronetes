# syntax=docker/dockerfile:1
# COPY-only assembly of the all-Rust kind-style node image (per arch).
ARG GHCR=ghcr.io/indyjonesnl/rusternetes
ARG RUSTERNETES_IMAGE_TAG=main
FROM ${GHCR}/api-server:${RUSTERNETES_IMAGE_TAG}         AS src-apiserver
FROM ${GHCR}/scheduler:${RUSTERNETES_IMAGE_TAG}          AS src-scheduler
FROM ${GHCR}/controller-manager:${RUSTERNETES_IMAGE_TAG} AS src-cm
FROM ${GHCR}/kubelet:${RUSTERNETES_IMAGE_TAG}            AS src-kubelet
FROM ${GHCR}/kube-proxy:${RUSTERNETES_IMAGE_TAG}         AS src-kubeproxy

FROM debian:sid-slim
ARG CNI_ARCH=amd64
ARG CRUN_ARCH=amd64
ARG CONTAINERD_RS_ARCH=amd64
ARG CONTAINERD_RS_VERSION=v0.3.0
RUN apt-get update && apt-get install -y --no-install-recommends \
      iptables iproute2 ca-certificates curl openssl && rm -rf /var/lib/apt/lists/*

# rusternetes binaries (fork multi-arch images; /app/<name>)
COPY --from=src-apiserver  /app/api-server         /usr/local/bin/api-server
COPY --from=src-scheduler  /app/scheduler          /usr/local/bin/scheduler
COPY --from=src-cm         /app/controller-manager /usr/local/bin/controller-manager
COPY --from=src-kubelet    /app/kubelet            /usr/local/bin/kubelet
COPY --from=src-kubeproxy  /app/kube-proxy         /usr/local/bin/kube-proxy

# containerd-rs + crun (release artifacts, arch-selected)
RUN curl -fsSL "https://github.com/indyjonesnl/containerd-rs/releases/download/${CONTAINERD_RS_VERSION}/containerd-rs_${CONTAINERD_RS_VERSION}_linux_${CONTAINERD_RS_ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin \
 && curl -fsSL -o /usr/local/bin/crun \
      "https://github.com/containers/crun/releases/download/1.28/crun-1.28-linux-${CRUN_ARCH}" \
 && chmod +x /usr/local/bin/containerd-rs /usr/local/bin/crun

# CNI plugins + flannel shim. Conflist goes in containerd-rs's cni_conf_dir
# (/etc/cni/net.d, per the proven k0s-diff config).
RUN mkdir -p /opt/cni/bin /etc/cni/net.d \
 && curl -fsSL "https://github.com/containernetworking/plugins/releases/download/v1.9.1/cni-plugins-linux-${CNI_ARCH}-v1.9.1.tgz" \
      | tar -xz -C /opt/cni/bin \
 && curl -fsSL "https://github.com/flannel-io/cni-plugin/releases/download/v1.9.1-flannel1/cni-plugin-flannel-linux-${CNI_ARCH}-v1.9.1.tgz" \
      | tar -xz -C /tmp \
 && mv "/tmp/flannel-${CNI_ARCH}" /opt/cni/bin/flannel
COPY deploy/dind/10-flannel.conflist        /etc/cni/net.d/10-flannel.conflist
COPY deploy/dind/config-containerd-rs.toml  /etc/containerd-rs/config.toml

# Baked CI-only PKI + insecure kubeconfig (server 10.88.0.2 for all roles)
RUN mkdir -p /etc/rusternetes/pki && cd /etc/rusternetes/pki \
 && openssl genrsa -out ca.key 2048 \
 && openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
      -subj "/CN=rusternetes-ca/O=mikronetes" \
 && openssl genrsa -out server.key 2048 \
 && openssl req -new -key server.key -out server.csr -subj "/CN=rusternetes-api/O=mikronetes" \
 && printf 'subjectAltName=DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.cluster.local,DNS:api-server,DNS:node-1,IP:127.0.0.1,IP:10.88.0.2,IP:10.96.0.1\n' > server.ext \
 && openssl x509 -req -days 3650 -in server.csr -CA ca.crt -CAkey ca.key \
      -CAcreateserial -out server.crt -extfile server.ext \
 && cat ca.crt >> server.crt \
 && rm -f server.csr ca.srl
RUN printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster:\n    server: https://10.88.0.2:6443\n    insecure-skip-tls-verify: true\ncontexts:\n- name: c\n  context: {cluster: c, user: u}\ncurrent-context: c\nusers:\n- name: u\n  user: {token: dummy}\n' \
      > /etc/rusternetes/kubeconfig

COPY deploy/dind/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
