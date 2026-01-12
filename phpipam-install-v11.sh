#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# phpipam-install-v6.sh
# Instala phpIPAM com HTTPS atrás de Nginx (porta externa 8443) focado em API.
#
# Regras desta versão:
# - Por padrão, NÃO exige --ip nem --dns-name.
# - O DNS padrão é extraído de /opt/inoc-config/.env (caminho do Let's Encrypt).
# - O IP padrão é resolvido a partir do DNS extraído (getent).
# - Mantém a porta 8443 em redirects e links (X-Forwarded-* + proxy_redirect).
################################################################################

print_help() {
    cat <<'EOF'
Uso:
  ./phpipam-install-v6.sh [opções]

Opções (todas opcionais):
  --ip <IPv4>                 Força o IP público (padrão: resolve via DNS do certificado)
  --dns-name <nome>           Força o nome DNS de acesso (padrão: extraído do certificado Let's Encrypt)
  --tls-dns-name <nome>       Força o nome DNS para TLS (padrão: igual ao DNS extraído do certificado)
  -h, --help                  Mostra esta ajuda

Comportamento padrão (sem parâmetros):
  - Lê /opt/inoc-config/.env
  - Usa SSL_CERT_PATH/SSL_KEY_PATH para extrair o domínio em /etc/letsencrypt/live/<DOMINIO>/
  - Sobe phpIPAM em:
      HTTPS: https://<DOMINIO>:8443
      HTTP : http://<DOMINIO>:8099  (redireciona para HTTPS:8443)
EOF
}

log_info() {
    echo "==> $*"
}

log_warn() {
    echo " [AVISO] $*" >&2
}

log_error() {
    echo " [ERRO] $*" >&2
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Execute como root."
        exit 1
    fi
}

read_env_value() {
    local env_file="$1"
    local key="$2"

    if [[ ! -f "${env_file}" ]]; then
        echo ""
        return 0
    fi

    # Mantém exatamente o conteúdo após "="
    local line
    line="$(grep -E "^${key}=" "${env_file}" | head -n 1 || true)"
    if [[ -z "${line}" ]]; then
        echo ""
        return 0
    fi

    echo "${line#*=}"
}

resolve_ipv4_from_dns() {
    local dns_name="$1"
    local resolved_ipv4=""

    # getent ahostsv4 retorna várias linhas; pega a primeira coluna da primeira linha
    resolved_ipv4="$(getent ahostsv4 "${dns_name}" 2>/dev/null | awk 'NR==1{print $1}' || true)"

    if [[ -z "${resolved_ipv4}" ]]; then
        resolved_ipv4="$(getent hosts "${dns_name}" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    fi

    echo "${resolved_ipv4}"
}

generate_secret_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 18
        return 0
    fi

    # Fallback sem openssl
    tr -dc 'a-f0-9' </dev/urandom | head -c 36
    echo
}

install_packages_and_docker() {
    log_info "Instalando pacotes básicos..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        openssl

    log_info "Configurando repositório oficial do Docker..."
    install -m 0755 -d /etc/apt/keyrings

    if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
        rm -f /etc/apt/sources.list.d/docker.list
    fi

    if [[ -f /etc/apt/sources.list.d/docker.sources ]]; then
        log_warn "Removendo entrada antiga /etc/apt/sources.list.d/docker.sources"
        rm -f /etc/apt/sources.list.d/docker.sources
    fi

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    local ubuntu_codename
    ubuntu_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${ubuntu_codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -y

    log_info "Instalando Docker Engine e Docker Compose..."
    apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker >/dev/null 2>&1 || true
}

main() {
    require_root

    local forced_ip=""
    local forced_dns_name=""
    local forced_tls_dns_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)
                forced_ip="${2:-}"
                shift 2
                ;;
            --dns-name)
                forced_dns_name="${2:-}"
                shift 2
                ;;
            --tls-dns-name)
                forced_tls_dns_name="${2:-}"
                shift 2
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            *)
                log_error "Parâmetro desconhecido: $1"
                echo
                print_help
                exit 2
                ;;
        esac
    done

    local inoc_config_env="/opt/inoc-config/.env"
    if [[ ! -f "${inoc_config_env}" ]]; then
        log_error "Arquivo não encontrado: ${inoc_config_env}"
        exit 1
    fi

    local ssl_key_path
    local ssl_cert_path

    ssl_key_path="$(read_env_value "${inoc_config_env}" "SSL_KEY_PATH")"
    ssl_cert_path="$(read_env_value "${inoc_config_env}" "SSL_CERT_PATH")"

    if [[ -z "${ssl_key_path}" ]]; then
        log_error "SSL_KEY_PATH não encontrado em ${inoc_config_env}"
        exit 1
    fi

    if [[ -z "${ssl_cert_path}" ]]; then
        log_error "SSL_CERT_PATH não encontrado em ${inoc_config_env}"
        exit 1
    fi

    if [[ ! -f "${ssl_key_path}" ]]; then
        log_error "Arquivo de chave não encontrado: ${ssl_key_path}"
        exit 1
    fi

    if [[ ! -f "${ssl_cert_path}" ]]; then
        log_error "Arquivo de certificado não encontrado: ${ssl_cert_path}"
        exit 1
    fi

    local default_tls_dns_name=""
    if [[ "${ssl_cert_path}" =~ /etc/letsencrypt/live/([^/]+)/ ]]; then
        default_tls_dns_name="${BASH_REMATCH[1]}"
    elif [[ "${ssl_key_path}" =~ /etc/letsencrypt/live/([^/]+)/ ]]; then
        default_tls_dns_name="${BASH_REMATCH[1]}"
    else
        log_error "Não foi possível extrair o domínio a partir do caminho /etc/letsencrypt/live/<DOMINIO>/"
        log_error "SSL_CERT_PATH atual: ${ssl_cert_path}"
        log_error "SSL_KEY_PATH  atual: ${ssl_key_path}"
        exit 1
    fi

    local phpipam_dns_name="${default_tls_dns_name}"
    local phpipam_tls_dns_name="${default_tls_dns_name}"

    if [[ -n "${forced_dns_name}" ]]; then
        phpipam_dns_name="${forced_dns_name}"
    fi

    if [[ -n "${forced_tls_dns_name}" ]]; then
        phpipam_tls_dns_name="${forced_tls_dns_name}"
    fi

    local resolved_ip=""
    resolved_ip="$(resolve_ipv4_from_dns "${phpipam_dns_name}")"

    if [[ -z "${resolved_ip}" ]]; then
        resolved_ip="$(resolve_ipv4_from_dns "${phpipam_tls_dns_name}")"
    fi

    local phpipam_public_ip="${resolved_ip}"
    if [[ -n "${forced_ip}" ]]; then
        phpipam_public_ip="${forced_ip}"
    fi

    if [[ -z "${phpipam_public_ip}" ]]; then
        log_warn "Não foi possível resolver o IP via DNS. Você pode forçar com: --ip <IPv4>"
    fi

    local install_dir="/opt/phpipam"
    local nginx_dir="${install_dir}/nginx"
    local data_dir="${install_dir}/data"
    local env_file="${install_dir}/.env"
    local compose_file="${install_dir}/docker-compose.yml"

    local phpipam_http_port="8099"
    local phpipam_https_port="8443"

    log_info "Instalando phpIPAM com HTTPS (foco na API)..."
    log_info "DNS (acesso):       ${phpipam_dns_name}"
    log_info "DNS (TLS/cert):     ${phpipam_tls_dns_name}"
    log_info "IP (público):       ${phpipam_public_ip:-"(não resolvido)"}"
    log_info "HTTPS (porta fixa): ${phpipam_https_port}"
    log_info "HTTP  (porta fixa): ${phpipam_http_port}"

    install_packages_and_docker

    log_info "Criando diretório de instalação em ${install_dir}..."
    mkdir -p "${install_dir}"
    mkdir -p "${nginx_dir}"
    mkdir -p "${data_dir}/mariadb"

    # Mantém segredos existentes, se já existir .env
    local mariadb_root_password
    local mariadb_database
    local mariadb_user
    local mariadb_password
    local timezone_value

    mariadb_root_password="$(read_env_value "${env_file}" "MARIADB_ROOT_PASSWORD")"
    mariadb_database="$(read_env_value "${env_file}" "MARIADB_DATABASE")"
    mariadb_user="$(read_env_value "${env_file}" "MARIADB_USER")"
    mariadb_password="$(read_env_value "${env_file}" "MARIADB_PASSWORD")"
    timezone_value="$(read_env_value "${env_file}" "TZ")"

    if [[ -z "${mariadb_root_password}" ]]; then
        mariadb_root_password="$(generate_secret_hex)"
    fi

    if [[ -z "${mariadb_database}" ]]; then
        mariadb_database="phpipam"
    fi

    if [[ -z "${mariadb_user}" ]]; then
        mariadb_user="phpipam"
    fi

    if [[ -z "${mariadb_password}" ]]; then
        mariadb_password="$(generate_secret_hex)"
    fi

    if [[ -z "${timezone_value}" ]]; then
        timezone_value="Etc/UTC"
    fi

    log_info "Gerando ${env_file}..."
    umask 077
    cat > "${env_file}" <<EOF
PHPIPAM_PUBLIC_IP=${phpipam_public_ip}
PHPIPAM_DNS_NAME=${phpipam_dns_name}
PHPIPAM_TLS_DNS_NAME=${phpipam_tls_dns_name}

PHPIPAM_HTTP_PORT=${phpipam_http_port}
PHPIPAM_HTTPS_PORT=${phpipam_https_port}

SSL_KEY_PATH=${ssl_key_path}
SSL_CERT_PATH=${ssl_cert_path}

MARIADB_ROOT_PASSWORD=${mariadb_root_password}
MARIADB_DATABASE=${mariadb_database}
MARIADB_USER=${mariadb_user}
MARIADB_PASSWORD=${mariadb_password}

TZ=${timezone_value}
EOF
    umask 022

    log_info "Gerando nginx/phpipam.conf (mantendo porta 8443 em redirects e links)..."
    cat > "${nginx_dir}/phpipam.conf" <<EOF
# phpIPAM reverse proxy (HTTPS externo na porta ${phpipam_https_port})
# - Mantém :${phpipam_https_port} em redirects absolutos (proxy_redirect)
# - Envia X-Forwarded-* (inclui porta) para o phpIPAM
# - Remove default.conf do nginx via entrypoint (para não conflitar)

server {
    listen 80;
    server_name ${phpipam_dns_name} ${phpipam_tls_dns_name};

    return 301 https://\$host:${phpipam_https_port}\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${phpipam_dns_name} ${phpipam_tls_dns_name};

    ssl_certificate     ${ssl_cert_path};
    ssl_certificate_key ${ssl_key_path};

    client_max_body_size 64m;

    # Para referência interna nesta config
    set \$external_port ${phpipam_https_port};

    location / {
        proxy_pass http://phpipam-web:80;

        # Mantém Host com porta externa, para o app gerar URLs com :8443
        proxy_set_header Host \$host:\$external_port;

        # Headers padrão de proxy
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # Headers críticos para scheme/host/porta atrás de TLS e porta não padrão
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port \$external_port;
        proxy_set_header X-Forwarded-Host \$host:\$external_port;

        # Em alguns ambientes, ajuda na detecção correta
        proxy_set_header X-Forwarded-Ssl on;

        # Reescreve redirects absolutos do upstream para manter https e porta externa
        proxy_redirect ~^http://[^/]+(.*)\$  https://\$host:\$external_port\$1;
        proxy_redirect ~^https://[^/]+(.*)\$ https://\$host:\$external_port\$1;

        proxy_buffering off;
    }
}
EOF

    log_info "Gerando nginx/entrypoint.sh..."
    cat > "${nginx_dir}/entrypoint.sh" <<'EOF'
#!/bin/sh
set -eu

# Remove conf padrão do nginx oficial para evitar conflito com nosso server block
rm -f /etc/nginx/conf.d/default.conf

exec nginx -g "daemon off;"
EOF
    chmod +x "${nginx_dir}/entrypoint.sh"

    log_info "Gerando docker-compose.yml..."
    cat > "${compose_file}" <<'EOF'
services:
  mariadb:
    image: mariadb:11
    container_name: phpipam-mariadb
    environment:
      MYSQL_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MARIADB_DATABASE}
      MYSQL_USER: ${MARIADB_USER}
      MYSQL_PASSWORD: ${MARIADB_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./data/mariadb:/var/lib/mysql
    restart: unless-stopped
    networks:
      - phpipam-net

  phpipam-web:
    image: phpipam/phpipam-www:latest
    container_name: phpipam-web
    depends_on:
      - mariadb
    environment:
      IPAM_DATABASE_HOST: mariadb
      IPAM_DATABASE_NAME: ${MARIADB_DATABASE}
      IPAM_DATABASE_USER: ${MARIADB_USER}
      IPAM_DATABASE_PASS: ${MARIADB_PASSWORD}
      IPAM_TRUST_X_FORWARDED: "true"
      TZ: ${TZ}
    restart: unless-stopped
    networks:
      - phpipam-net

  phpipam-cron:
    image: phpipam/phpipam-cron:latest
    container_name: phpipam-cron
    depends_on:
      - phpipam-web
    environment:
      IPAM_DATABASE_HOST: mariadb
      IPAM_DATABASE_NAME: ${MARIADB_DATABASE}
      IPAM_DATABASE_USER: ${MARIADB_USER}
      IPAM_DATABASE_PASS: ${MARIADB_PASSWORD}
      IPAM_TRUST_X_FORWARDED: "true"
      TZ: ${TZ}
    restart: unless-stopped
    networks:
      - phpipam-net

  phpipam-nginx:
    image: nginx:1.27
    container_name: phpipam-nginx
    depends_on:
      - phpipam-web
    ports:
      - "${PHPIPAM_HTTP_PORT}:80"
      - "${PHPIPAM_HTTPS_PORT}:443"
    volumes:
      - ./nginx/phpipam.conf:/etc/nginx/conf.d/phpipam.conf:ro
      - ./nginx/entrypoint.sh:/entrypoint.sh:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    entrypoint: ["/bin/sh", "/entrypoint.sh"]
    restart: unless-stopped
    networks:
      - phpipam-net

networks:
  phpipam-net:
    driver: bridge
EOF

    log_info "Subindo o stack phpIPAM com HTTPS..."
    (cd "${install_dir}" && docker compose down --remove-orphans) || true
    (cd "${install_dir}" && docker compose pull)
    (cd "${install_dir}" && docker compose up -d)

    log_info "Containers em execução:"
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" | sed -n '1p;/phpipam-/p'

    log_info "Diagnóstico automático (redirect e base href mantendo :${phpipam_https_port})..."
    echo "---- Redirect (HTTPS /) ----"
    curl -skI "https://127.0.0.1:${phpipam_https_port}/" | egrep -i 'HTTP/|location:' || true

    echo
    echo "---- Base href (login) ----"
    curl -sk "https://127.0.0.1:${phpipam_https_port}/index.php?page=login" | grep -i "<base href" || true

    echo
    log_info "Acesso esperado:"
    log_info "  https://${phpipam_dns_name}:${phpipam_https_port}/"
}

main "$@"
