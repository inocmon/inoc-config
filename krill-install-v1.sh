#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Configurações
# =========================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/krill-docker}"

IMAGE_NAME="${IMAGE_NAME:-krill-local:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-krill}"

HOST_BIND_IP="${HOST_BIND_IP:-127.0.0.1}"
HOST_PORT="${HOST_PORT:-3000}"

KRILL_TOKEN="${KRILL_TOKEN:-}"
KRILL_ADMIN_TOKEN="${KRILL_ADMIN_TOKEN:-}"
KRILL_SERVICE_URI="${KRILL_SERVICE_URI:-https://localhost:3000/}"
KRILL_GIT_REF="${KRILL_GIT_REF:-main}"

# =========================================================
# Funções utilitárias
# =========================================================
require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "ERRO: execute este script como root."
    exit 1
  fi
}

ensure_base_dependencies() {
  export DEBIAN_FRONTEND=noninteractive

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERRO: este script foi preparado para sistemas baseados em apt-get (Ubuntu e Debian)."
    exit 1
  fi

  apt-get update
  apt-get install -y ca-certificates curl git openssl gnupg
}

install_docker_official_repo() {
  export DEBIAN_FRONTEND=noninteractive

  apt-get update
  apt-get install -y ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings

  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  ARCH="$(dpkg --print-architecture)"

  printf "deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n" "${ARCH}" "${CODENAME}" > /etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
}

ensure_docker_installed() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi

  install_docker_official_repo

  if ! command -v docker >/dev/null 2>&1; then
    echo "ERRO: Docker não foi instalado corretamente."
    exit 1
  fi
}

ensure_compose_available() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  echo "ERRO: 'docker compose' não está disponível mesmo após instalar o plugin."
  echo "Verifique se o pacote docker-compose-plugin foi instalado corretamente."
  exit 1
}

load_existing_env_if_present() {
  if [ -f "${INSTALL_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${INSTALL_DIR}/.env"
    set +a
  fi
}

generate_token_if_missing() {
  if [ -n "${KRILL_TOKEN}" ]; then
    return 0
  fi

  KRILL_TOKEN="$(openssl rand -hex 24)"
}

generate_admin_token_if_missing() {
  if [ -n "${KRILL_ADMIN_TOKEN}" ]; then
    return 0
  fi

  if [ -n "${KRILL_TOKEN}" ]; then
    KRILL_ADMIN_TOKEN="${KRILL_TOKEN}"
    return 0
  fi

  KRILL_ADMIN_TOKEN="$(openssl rand -hex 24)"
}

write_files() {
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  cat > Dockerfile <<'DOCKERFILE'
FROM ubuntu:24.04 AS builder

ARG KRILL_GIT_REF=main

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    openssl \
    pkg-config \
    curl \
    git \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /src
RUN git clone https://github.com/NLnetLabs/krill.git

WORKDIR /src/krill
RUN git checkout "${KRILL_GIT_REF}" \
 && cargo build --release

RUN mkdir -p /out/bin /out/defaults \
 && cp /src/krill/target/release/krill  /out/bin/krill \
 && cp /src/krill/target/release/krillc /out/bin/krillc \
 && cp /src/krill/defaults/krill.conf /out/defaults/krill.conf

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -r -m -d /var/krill -s /usr/sbin/nologin krill \
 && mkdir -p /var/krill/data \
 && chown -R krill:krill /var/krill

COPY --from=builder /out/bin/krill  /usr/local/bin/krill
COPY --from=builder /out/bin/krillc /usr/local/bin/krillc
COPY --from=builder /out/defaults/krill.conf /usr/local/share/krill/krill.conf.default

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh \
 && chmod +x /usr/local/bin/krill \
 && chmod +x /usr/local/bin/krillc

EXPOSE 3000

WORKDIR /var/krill/data

USER krill
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["/usr/local/bin/krill", "-c", "/var/krill/data/krill.conf"]
DOCKERFILE

  cat > docker-entrypoint.sh <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="/var/krill/data/krill.conf"
DEFAULT_CONFIG="/usr/local/share/krill/krill.conf.default"

KRILL_TOKEN="${KRILL_TOKEN:-}"
KRILL_ADMIN_TOKEN="${KRILL_ADMIN_TOKEN:-}"
KRILL_SERVICE_URI="${KRILL_SERVICE_URI:-}"

if [ -z "${KRILL_ADMIN_TOKEN}" ] && [ -n "${KRILL_TOKEN}" ]; then
  KRILL_ADMIN_TOKEN="${KRILL_TOKEN}"
fi

if [ ! -f "${CONFIG_PATH}" ]; then
  cp "${DEFAULT_CONFIG}" "${CONFIG_PATH}"
fi

if grep -qE '^[[:space:]]*data_dir[[:space:]]*=' "${CONFIG_PATH}"; then
  sed -i 's|^[[:space:]]*data_dir[[:space:]]*=.*|data_dir = "/var/krill/data"|' "${CONFIG_PATH}"
else
  printf '\ndata_dir = "/var/krill/data"\n' >> "${CONFIG_PATH}"
fi

if [ -n "${KRILL_TOKEN}" ]; then
  if grep -qE '^[[:space:]]*auth_token[[:space:]]*=' "${CONFIG_PATH}"; then
    sed -i "s|^[[:space:]]*auth_token[[:space:]]*=.*|auth_token = \"${KRILL_TOKEN}\"|" "${CONFIG_PATH}"
  fi
fi

if [ -n "${KRILL_ADMIN_TOKEN}" ]; then
  if grep -qE '^[[:space:]]*admin_token[[:space:]]*=' "${CONFIG_PATH}"; then
    sed -i "s|^[[:space:]]*admin_token[[:space:]]*=.*|admin_token = \"${KRILL_ADMIN_TOKEN}\"|" "${CONFIG_PATH}"
  else
    printf '\nadmin_token = "%s"\n' "${KRILL_ADMIN_TOKEN}" >> "${CONFIG_PATH}"
  fi
fi

if [ -n "${KRILL_SERVICE_URI}" ]; then
  if grep -qE '^[[:space:]]*service_uri[[:space:]]*=' "${CONFIG_PATH}"; then
    sed -i "s|^[[:space:]]*service_uri[[:space:]]*=.*|service_uri = \"${KRILL_SERVICE_URI}\"|" "${CONFIG_PATH}"
  fi
fi

if grep -qE '^[[:space:]]*ip[[:space:]]*=' "${CONFIG_PATH}"; then
  sed -i 's|^[[:space:]]*ip[[:space:]]*=.*|ip = "0.0.0.0"|' "${CONFIG_PATH}"
else
  printf '\nip = "0.0.0.0"\n' >> "${CONFIG_PATH}"
fi

cd /var/krill/data
exec "$@"
ENTRYPOINT

  cat > docker-compose.yml <<'COMPOSE'
services:
  krill:
    build:
      context: .
      args:
        KRILL_GIT_REF: ${KRILL_GIT_REF}
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      KRILL_TOKEN: ${KRILL_TOKEN}
      KRILL_ADMIN_TOKEN: ${KRILL_ADMIN_TOKEN}
      KRILL_SERVICE_URI: ${KRILL_SERVICE_URI}
    ports:
      - "${HOST_BIND_IP}:${HOST_PORT}:3000"
    volumes:
      - krill_data:/var/krill/data
volumes:
  krill_data:
COMPOSE
}

write_env_file() {
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  if [ -f "${INSTALL_DIR}/.env" ]; then
    load_existing_env_if_present
  fi

  if [ -z "${KRILL_TOKEN}" ]; then
    generate_token_if_missing
  fi

  if [ -z "${KRILL_ADMIN_TOKEN}" ]; then
    generate_admin_token_if_missing
  fi

  cat > .env <<ENVFILE
IMAGE_NAME=${IMAGE_NAME}
CONTAINER_NAME=${CONTAINER_NAME}
HOST_BIND_IP=${HOST_BIND_IP}
HOST_PORT=${HOST_PORT}
KRILL_TOKEN=${KRILL_TOKEN}
KRILL_ADMIN_TOKEN=${KRILL_ADMIN_TOKEN}
KRILL_SERVICE_URI=${KRILL_SERVICE_URI}
KRILL_GIT_REF=${KRILL_GIT_REF}
ENVFILE
}

build_and_up() {
  cd "${INSTALL_DIR}"

  docker compose build
  docker compose up -d --force-recreate
}

show_status() {
  echo
  echo "Instalação em: ${INSTALL_DIR}"
  echo "Container: ${CONTAINER_NAME}"
  echo "Imagem: ${IMAGE_NAME}"
  echo "Publicação: ${HOST_BIND_IP}:${HOST_PORT} -> 3000 (container)"
  echo "service_uri: ${KRILL_SERVICE_URI}"
  echo "Token (KRILL_TOKEN) salvo em ${INSTALL_DIR}/.env: ${KRILL_TOKEN}"
  echo "Admin token (KRILL_ADMIN_TOKEN) salvo em ${INSTALL_DIR}/.env: ${KRILL_ADMIN_TOKEN}"
  echo

  echo "Status do container:"
  docker ps --filter "name=${CONTAINER_NAME}" --format '  {{.Names}}  |  {{.Status}}  |  {{.Ports}}' || true

  echo
  echo "Logs do Krill (últimas 120 linhas):"
  docker logs --tail 120 "${CONTAINER_NAME}" || true

  echo
  echo "Teste local:"
  echo "  curl -k https://localhost:${HOST_PORT}/"
  echo
}

# =========================================================
# Execução
# =========================================================
require_root
ensure_base_dependencies
ensure_docker_installed
ensure_compose_available

write_files
write_env_file
build_and_up
show_status
