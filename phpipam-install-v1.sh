#!/usr/bin/env bash
set -euo pipefail

### ==============================
### VARIÁVEIS AJUSTÁVEIS
### ==============================
INSTALL_DIR="/opt/phpipam"
PHPIPAM_VERSION="latest"

# Troque estas senhas antes de usar em produção
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-TroqueEssaSenhaRoot!}"
PHPIPAM_DB_PASSWORD="${PHPIPAM_DB_PASSWORD:-TroqueEssaSenhaPhpipam!}"

# Timezone do servidor / containers
TIMEZONE="${TIMEZONE:-America/Fortaleza}"

### ==============================
### CHECAGENS INICIAIS
### ==============================
if [[ "$(id -u)" -ne 0 ]]; then
  echo " [ERRO] Execute este script como root (sudo)." >&2
  exit 1
fi

echo "==> Instalando phpIPAM em container (Docker) no Ubuntu 24.04..."

### ==============================
### INSTALAR DEPENDÊNCIAS BÁSICAS
### ==============================
echo "==> Instalando pacotes básicos..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

### ==============================
### CONFIGURAR REPOSITÓRIO OFICIAL DO DOCKER
### (conforme documentação oficial)
### ==============================
echo "==> Configurando repositório oficial do Docker..."

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
fi
chmod a+r /etc/apt/keyrings/docker.asc

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update -y

### ==============================
### INSTALAR DOCKER ENGINE + DOCKER COMPOSE PLUGIN
### ==============================
echo "==> Instalando Docker Engine e Docker Compose..."
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

# Permitir que o usuário atual use docker sem sudo (opcional)
if id "${SUDO_USER:-}" &>/dev/null; then
  echo "==> Adicionando o usuário ${SUDO_USER} ao grupo docker..."
  usermod -aG docker "${SUDO_USER}"
fi

echo "==> Docker instalado. Versões:"
docker --version || true
docker compose version || true

### ==============================
### CRIAR ARQUIVOS DO PHPIPAM (DOCKER COMPOSE)
### ==============================
echo "==> Criando diretório de instalação em ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

if [[ -f docker-compose.yml ]]; then
  echo " [AVISO] Já existe um docker-compose.yml em ${INSTALL_DIR}. Ele será sobrescrito."
fi

cat > docker-compose.yml <<EOF
version: '3.8'

services:
  phpipam-web:
    image: phpipam/phpipam-www:${PHPIPAM_VERSION}
    container_name: phpipam-web
    ports:
      - "8099:80"
    environment:
      - TZ=${TIMEZONE}
      - IPAM_DATABASE_HOST=phpipam-mariadb
      - IPAM_DATABASE_USER=phpipam
      - IPAM_DATABASE_PASS=${PHPIPAM_DB_PASSWORD}
      - IPAM_DATABASE_NAME=phpipam
      - IPAM_DATABASE_WEBHOST=%
    restart: unless-stopped
    volumes:
      - phpipam-logo:/phpipam/css/images/logo
      - phpipam-ca:/usr/local/share/ca-certificates:ro
    depends_on:
      - phpipam-mariadb
    cap_add:
      - NET_ADMIN
      - NET_RAW

  phpipam-cron:
    image: phpipam/phpipam-cron:${PHPIPAM_VERSION}
    container_name: phpipam-cron
    environment:
      - TZ=${TIMEZONE}
      - IPAM_DATABASE_HOST=phpipam-mariadb
      - IPAM_DATABASE_USER=phpipam
      - IPAM_DATABASE_PASS=${PHPIPAM_DB_PASSWORD}
      - IPAM_DATABASE_NAME=phpipam
      - SCAN_INTERVAL=1h
    restart: unless-stopped
    volumes:
      - phpipam-ca:/usr/local/share/ca-certificates:ro
    depends_on:
      - phpipam-mariadb
    cap_add:
      - NET_ADMIN
      - NET_RAW

  phpipam-mariadb:
    image: mariadb:11
    container_name: phpipam-mariadb
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=phpipam
      - MYSQL_USER=phpipam
      - MYSQL_PASSWORD=${PHPIPAM_DB_PASSWORD}
    restart: unless-stopped
    volumes:
      - phpipam-db-data:/var/lib/mysql

volumes:
  phpipam-db-data:
  phpipam-logo:
  phpipam-ca:
EOF

echo "==> Arquivo docker-compose.yml criado em ${INSTALL_DIR}."

### ==============================
### SUBIR OS CONTAINERS
### ==============================
echo "==> Baixando imagens e subindo o stack phpIPAM..."
docker compose pull
docker compose up -d

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo "============================================================"
echo " INSTALAÇÃO BÁSICA FINALIZADA!"
echo
echo "  - Diretório de instalação: ${INSTALL_DIR}"
echo "  - Containers criados: phpipam-web, phpipam-cron, phpipam-mariadb"
echo "  - Banco de dados:"
echo "      Host: phpipam-mariadb (de dentro do container)"
echo "      DB:   phpipam"
echo "      User: phpipam"
echo "      Pass: ${PHPIPAM_DB_PASSWORD}"
echo
echo "  - Acesse no navegador:"
if [[ -n "\${IP_ADDR}" ]]; then
  echo "      http://${IP_ADDR}/"
else
  echo "      http://<IP-do-servidor>/"
fi
echo
echo "  OBS:"
echo "    1) No primeiro acesso, conclua o assistente do phpIPAM."
echo "    2) Depois da instalação, é recomendado desativar o instalador"
echo "       definindo IPAM_DISABLE_INSTALLER=1 no serviço phpipam-web."
echo "============================================================"
echo
