#!/bin/sh
set -eu

PROJECT_DIR="/opt/tftp-docker"
TFTPBOOT_DIR="/opt/tftp-docker/tftpboot"

CONTAINER_NAME="tftp-server"
IMAGE_NAME="tftp-local:latest"

TFTP_PORT="69"
PORT_RANGE_START="40000"
PORT_RANGE_END="40100"

TFTP_CREATE="false"
TFTP_PERMISSIVE="false"
TFTP_UMASK="022"

APPLY_FIREWALL="true"

PRIVATE_CIDRS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERRO: docker não encontrado no PATH."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERRO: docker compose não está disponível."
    exit 1
fi

mkdir -p "${PROJECT_DIR}"
mkdir -p "${TFTPBOOT_DIR}"

chmod 0755 "${TFTPBOOT_DIR}"

if command -v find >/dev/null 2>&1; then
    find "${TFTPBOOT_DIR}" -type f -exec chmod 0644 {} \;
fi

cat > "${PROJECT_DIR}/Dockerfile" <<'EOF'
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tftpd-hpa ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN if ! id -u tftp >/dev/null 2>&1; then \
        useradd \
            --system \
            --home /srv/tftp \
            --shell /usr/sbin/nologin \
            --create-home \
            tftp; \
    fi

RUN mkdir -p /srv/tftp \
    && chown -R tftp:tftp /srv/tftp \
    && chmod 0755 /srv/tftp

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

EXPOSE 69/udp
EXPOSE 40000-40100/udp

VOLUME ["/srv/tftp"]

ENTRYPOINT ["/entrypoint.sh"]
EOF

cat > "${PROJECT_DIR}/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu

TFTP_ROOT="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_PORT_RANGE="40000:40100"

TFTP_CREATE="${TFTP_CREATE:-false}"
TFTP_PERMISSIVE="${TFTP_PERMISSIVE:-false}"
TFTP_UMASK="${TFTP_UMASK:-022}"
TFTP_USER="tftp"

mkdir -p "${TFTP_ROOT}"
chown -R "${TFTP_USER}:${TFTP_USER}" "${TFTP_ROOT}"
chmod 0755 "${TFTP_ROOT}"

ARGS="--foreground --listen --address ${TFTP_ADDRESS} --secure --user ${TFTP_USER} --umask ${TFTP_UMASK} --port-range ${TFTP_PORT_RANGE} --verbose"

case "${TFTP_PERMISSIVE}" in
    1|true|TRUE|yes|YES)
        ARGS="${ARGS} --permissive"
        ;;
esac

case "${TFTP_CREATE}" in
    1|true|TRUE|yes|YES)
        ARGS="${ARGS} --create"
        ;;
esac

exec in.tftpd ${ARGS} "${TFTP_ROOT}"
EOF

chmod 0755 "${PROJECT_DIR}/entrypoint.sh"

cat > "${PROJECT_DIR}/docker-compose.yml" <<EOF
services:
  tftp:
    build:
      context: .
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped

    ports:
      - "${TFTP_PORT}:${TFTP_PORT}/udp"
      - "${PORT_RANGE_START}-${PORT_RANGE_END}:${PORT_RANGE_START}-${PORT_RANGE_END}/udp"

    volumes:
      - "${TFTPBOOT_DIR}:/srv/tftp"

    environment:
      TFTP_CREATE: "${TFTP_CREATE}"
      TFTP_PERMISSIVE: "${TFTP_PERMISSIVE}"
      TFTP_UMASK: "${TFTP_UMASK}"
EOF

if [ ! -f "${TFTPBOOT_DIR}/.keep" ]; then
    echo "Diretório TFTP" > "${TFTPBOOT_DIR}/.keep"
fi

chmod 0644 "${TFTPBOOT_DIR}/.keep"

cd "${PROJECT_DIR}"

docker compose down >/dev/null 2>&1 || true
docker compose build
docker compose up -d

if [ "${APPLY_FIREWALL}" = "true" ]; then
    if ! command -v iptables >/dev/null 2>&1; then
        echo "AVISO: iptables não encontrado. Firewall não foi aplicado."
    else
        if ! iptables -S DOCKER-USER >/dev/null 2>&1; then
            iptables -N DOCKER-USER >/dev/null 2>&1 || true
            iptables -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || iptables -I FORWARD 1 -j DOCKER-USER
            iptables -C DOCKER-USER -j RETURN >/dev/null 2>&1 || iptables -A DOCKER-USER -j RETURN
        fi

        iptables -D DOCKER-USER -p udp --dport "${TFTP_PORT}" -j DROP >/dev/null 2>&1 || true
        iptables -D DOCKER-USER -p udp --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j DROP >/dev/null 2>&1 || true

        for CIDR in ${PRIVATE_CIDRS}; do
            iptables -D DOCKER-USER -p udp -s "${CIDR}" --dport "${TFTP_PORT}" -j ACCEPT >/dev/null 2>&1 || true
            iptables -D DOCKER-USER -p udp -s "${CIDR}" --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j ACCEPT >/dev/null 2>&1 || true
        done

        for CIDR in ${PRIVATE_CIDRS}; do
            iptables -C DOCKER-USER -p udp -s "${CIDR}" --dport "${TFTP_PORT}" -j ACCEPT >/dev/null 2>&1 || \
                iptables -I DOCKER-USER 1 -p udp -s "${CIDR}" --dport "${TFTP_PORT}" -j ACCEPT

            iptables -C DOCKER-USER -p udp -s "${CIDR}" --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j ACCEPT >/dev/null 2>&1 || \
                iptables -I DOCKER-USER 1 -p udp -s "${CIDR}" --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j ACCEPT
        done

        iptables -C DOCKER-USER -p udp --dport "${TFTP_PORT}" -j DROP >/dev/null 2>&1 || \
            iptables -I DOCKER-USER 1 -p udp --dport "${TFTP_PORT}" -j DROP

        iptables -C DOCKER-USER -p udp --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j DROP >/dev/null 2>&1 || \
            iptables -I DOCKER-USER 1 -p udp --dport "${PORT_RANGE_START}:${PORT_RANGE_END}" -j DROP
    fi
fi

echo ""
echo "=========================================="
echo " SERVIDOR TFTP ATIVO"
echo "=========================================="
echo ""
echo "Diretório no HOST para arquivos TFTP:"
echo "  ${TFTPBOOT_DIR}"
echo ""
echo "Permissões aplicadas:"
echo "  Diretório: 0755"
echo "  Arquivos:  0644 (para arquivos já existentes)"
echo ""
echo "Exemplo para adicionar arquivo:"
echo "  cp firmware.bin ${TFTPBOOT_DIR}/firmware.bin"
echo "  chmod 0644 ${TFTPBOOT_DIR}/firmware.bin"
echo ""
echo "Restrição de rede:"
echo "  Apenas IPs privados podem acessar UDP ${TFTP_PORT} e UDP ${PORT_RANGE_START}-${PORT_RANGE_END}"
echo "  Redes permitidas: ${PRIVATE_CIDRS}"
echo ""
echo "Logs:"
echo "  cd ${PROJECT_DIR} && docker compose logs -f"
echo ""
echo "Parar:"
echo "  cd ${PROJECT_DIR} && docker compose down"
echo ""
