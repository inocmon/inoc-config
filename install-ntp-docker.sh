#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Configurações
# =========================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/ntp-docker}"

IMAGE_NAME="${IMAGE_NAME:-ntp-chrony-local:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-ntp-chrony}"

HOST_BIND_IP="${HOST_BIND_IP:-0.0.0.0}"
HOST_PORT="${HOST_PORT:-123}"

NTP_UPSTREAMS="${NTP_UPSTREAMS:-a.ntp.br b.ntp.br c.ntp.br}"

ALLOW_NETS="${ALLOW_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

ADJUST_HOST_CLOCK="${ADJUST_HOST_CLOCK:-yes}"

ENABLE_LOCAL_STRATUM="${ENABLE_LOCAL_STRATUM:-no}"
LOCAL_STRATUM="${LOCAL_STRATUM:-10}"

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
  apt-get install -y ca-certificates curl git openssl gnupg iproute2
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

check_udp_port_available() {
  if ss -ulnpH 2>/dev/null | awk '{print $5}' | grep -qE ":${HOST_PORT}$"; then
    echo "ERRO: a porta UDP ${HOST_PORT} já está em uso no host."
    echo "Verifique com:"
    echo "  ss -ulnp | grep -E \"(:${HOST_PORT}[[:space:]]|:${HOST_PORT}\$)\""
    echo
    echo "Se existir chrony, systemd-timesyncd, ntpd, ou outro serviço usando 123/udp, pare o serviço do host ou altere HOST_PORT."
    exit 1
  fi
}

write_files() {
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  cat > Dockerfile <<'DOCKERFILE'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    chrony \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 123/udp

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
DOCKERFILE

  cat > docker-entrypoint.sh <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

umask 022

NTP_UPSTREAMS="${NTP_UPSTREAMS:-a.ntp.br b.ntp.br c.ntp.br}"
ALLOW_NETS="${ALLOW_NETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"

ADJUST_HOST_CLOCK="${ADJUST_HOST_CLOCK:-yes}"

ENABLE_LOCAL_STRATUM="${ENABLE_LOCAL_STRATUM:-no}"
LOCAL_STRATUM="${LOCAL_STRATUM:-10}"

CONF_PATH="/etc/chrony/chrony.conf"

mkdir -p /var/lib/chrony
mkdir -p /var/log/chrony
mkdir -p /run/chrony

CHRONY_USER="_chrony"
CHRONY_GROUP="_chrony"

if ! id -u "${CHRONY_USER}" >/dev/null 2>&1; then
  CHRONY_USER="chrony"
  CHRONY_GROUP="chrony"
fi

chown -R "${CHRONY_USER}:${CHRONY_GROUP}" /var/lib/chrony
chown -R "${CHRONY_USER}:${CHRONY_GROUP}" /var/log/chrony
chown -R "${CHRONY_USER}:${CHRONY_GROUP}" /run/chrony

chmod 0755 /var/lib/chrony
chmod 0755 /var/log/chrony
chmod 0755 /run/chrony

: > "${CONF_PATH}"

printf '%s\n' "user ${CHRONY_USER}" >> "${CONF_PATH}"
printf '%s\n' 'driftfile /var/lib/chrony/chrony.drift' >> "${CONF_PATH}"
printf '%s\n' 'logdir /var/log/chrony' >> "${CONF_PATH}"
printf '%s\n' 'log tracking measurements statistics' >> "${CONF_PATH}"
printf '%s\n' 'makestep 1.0 3' >> "${CONF_PATH}"
printf '%s\n' 'rtcsync' >> "${CONF_PATH}"
printf '\n' >> "${CONF_PATH}"

for server in ${NTP_UPSTREAMS}; do
  printf 'server %s iburst\n' "${server}" >> "${CONF_PATH}"
done

printf '\n' >> "${CONF_PATH}"

for net in ${ALLOW_NETS}; do
  printf 'allow %s\n' "${net}" >> "${CONF_PATH}"
done

if [ "${ENABLE_LOCAL_STRATUM}" = "yes" ]; then
  printf '\n' >> "${CONF_PATH}"
  printf 'local stratum %s\n' "${LOCAL_STRATUM}" >> "${CONF_PATH}"
fi

if [ "${ADJUST_HOST_CLOCK}" = "yes" ]; then
  exec chronyd -d -f "${CONF_PATH}"
else
  exec chronyd -d -x -f "${CONF_PATH}"
fi
ENTRYPOINT

  if [ -f "${INSTALL_DIR}/.env" ]; then
    load_existing_env_if_present
  fi

  if [ "${ADJUST_HOST_CLOCK}" = "yes" ]; then
    cat > docker-compose.yml <<'COMPOSE'
services:
  ntp:
    build:
      context: .
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      NTP_UPSTREAMS: ${NTP_UPSTREAMS}
      ALLOW_NETS: ${ALLOW_NETS}
      ADJUST_HOST_CLOCK: ${ADJUST_HOST_CLOCK}
      ENABLE_LOCAL_STRATUM: ${ENABLE_LOCAL_STRATUM}
      LOCAL_STRATUM: ${LOCAL_STRATUM}
    ports:
      - "${HOST_BIND_IP}:${HOST_PORT}:123/udp"
    cap_add:
      - SYS_TIME
    volumes:
      - chrony_state:/var/lib/chrony
      - chrony_logs:/var/log/chrony
volumes:
  chrony_state:
  chrony_logs:
COMPOSE
  else
    cat > docker-compose.yml <<'COMPOSE'
services:
  ntp:
    build:
      context: .
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    environment:
      NTP_UPSTREAMS: ${NTP_UPSTREAMS}
      ALLOW_NETS: ${ALLOW_NETS}
      ADJUST_HOST_CLOCK: ${ADJUST_HOST_CLOCK}
      ENABLE_LOCAL_STRATUM: ${ENABLE_LOCAL_STRATUM}
      LOCAL_STRATUM: ${LOCAL_STRATUM}
    ports:
      - "${HOST_BIND_IP}:${HOST_PORT}:123/udp"
    volumes:
      - chrony_state:/var/lib/chrony
      - chrony_logs:/var/log/chrony
volumes:
  chrony_state:
  chrony_logs:
COMPOSE
  fi
}

write_env_file() {
  mkdir -p "${INSTALL_DIR}"
  cd "${INSTALL_DIR}"

  if [ -f "${INSTALL_DIR}/.env" ]; then
    load_existing_env_if_present
  fi

  cat > .env <<ENVFILE
IMAGE_NAME=${IMAGE_NAME}
CONTAINER_NAME=${CONTAINER_NAME}
HOST_BIND_IP=${HOST_BIND_IP}
HOST_PORT=${HOST_PORT}
NTP_UPSTREAMS=${NTP_UPSTREAMS}
ALLOW_NETS=${ALLOW_NETS}
ADJUST_HOST_CLOCK=${ADJUST_HOST_CLOCK}
ENABLE_LOCAL_STRATUM=${ENABLE_LOCAL_STRATUM}
LOCAL_STRATUM=${LOCAL_STRATUM}
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
  echo "Publicação: ${HOST_BIND_IP}:${HOST_PORT} -> 123/udp (container)"
  echo "Upstreams: ${NTP_UPSTREAMS}"
  echo "Redes liberadas (ALLOW_NETS): ${ALLOW_NETS}"
  echo "Ajustar relógio do host (ADJUST_HOST_CLOCK): ${ADJUST_HOST_CLOCK}"
  echo "Local stratum habilitado (ENABLE_LOCAL_STRATUM): ${ENABLE_LOCAL_STRATUM}"
  echo "Local stratum (LOCAL_STRATUM): ${LOCAL_STRATUM}"
  echo

  echo "Status do container:"
  docker ps --filter "name=${CONTAINER_NAME}" --format '  {{.Names}}  |  {{.Status}}  |  {{.Ports}}' || true

  echo
  echo "Logs do NTP (últimas 120 linhas):"
  docker logs --tail 120 "${CONTAINER_NAME}" || true

  echo
  echo "Testes dentro do container (Chrony):"
  echo "  docker exec -it ${CONTAINER_NAME} chronyc tracking"
  echo "  docker exec -it ${CONTAINER_NAME} chronyc sources -v"
  echo "  docker exec -it ${CONTAINER_NAME} chronyc clients"
  echo
}

# =========================================================
# Execução
# =========================================================
require_root
ensure_base_dependencies
ensure_docker_installed
ensure_compose_available
check_udp_port_available

write_files
write_env_file
build_and_up
show_status
