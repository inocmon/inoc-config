#!/usr/bin/env bash
set -euo pipefail

NOME_DO_CONTAINER="${NOME_DO_CONTAINER:-smokeping}"
IMAGEM_DO_CONTAINER_BASE="${IMAGEM_DO_CONTAINER_BASE:-lscr.io/linuxserver/smokeping:latest}"
IMAGEM_DO_CONTAINER="${IMAGEM_DO_CONTAINER:-inoc-smokeping:latest}"
PORTA_HTTP_NO_HOST="${PORTA_HTTP_NO_HOST:-8080}"

NOME_DO_CONTAINER_SINCRONIZADOR="${NOME_DO_CONTAINER_SINCRONIZADOR:-smokeping-sync}"
IMAGEM_DO_CONTAINER_SINCRONIZADOR="${IMAGEM_DO_CONTAINER_SINCRONIZADOR:-docker:cli}"

INTERVALO_SINCRONIZACAO_EM_MINUTOS="${INTERVALO_SINCRONIZACAO_EM_MINUTOS:-5}"
DIRETORIO_BASE_PADRAO="${DIRETORIO_BASE_PADRAO:-/opt/smokeping}"
MODO_INSTALACAO="${MODO_INSTALACAO:-update}"

TARGETS_JSON_BASE64=""
TARGETS_JSON_RAW=""
TARGETS_JSON_FILE=""
REMOVER_DADOS_ORFAOS="nao"
APAGAR_TODOS_DADOS="nao"

PROBE_FPING_BINARY="${PROBE_FPING_BINARY:-/usr/sbin/fping}"
PROBE_FPING_PINGS="${PROBE_FPING_PINGS:-100}"
PROBE_FPING_STEP="${PROBE_FPING_STEP:-60}"
PROBE_FPING_HOSTINTERVAL="${PROBE_FPING_HOSTINTERVAL:-0.5}"
PROBE_FPING_TIMEOUT="${PROBE_FPING_TIMEOUT:-1}"

PROBE_DNS_BINARY="${PROBE_DNS_BINARY:-/usr/bin/dig}"
PROBE_DNS_LOOKUP="${PROBE_DNS_LOOKUP:-google.com}"
PROBE_DNS_PINGS="${PROBE_DNS_PINGS:-30}"
PROBE_DNS_STEP="${PROBE_DNS_STEP:-60}"
PROBE_DNS_TIMEOUT="${PROBE_DNS_TIMEOUT:-1}"

PROBE_CURL_BINARY="${PROBE_CURL_BINARY:-/usr/bin/curl}"
PROBE_CURL_FORKS="${PROBE_CURL_FORKS:-2}"
PROBE_CURL_OFFSET="${PROBE_CURL_OFFSET:-50%}"
PROBE_CURL_STEP="${PROBE_CURL_STEP:-60}"
PROBE_CURL_PINGS="${PROBE_CURL_PINGS:-3}"
PROBE_CURL_EXTRAARGS="${PROBE_CURL_EXTRAARGS:--o /dev/null -sS --connect-timeout 1 --max-time 2}"
PROBE_CURL_URLFORMAT="${PROBE_CURL_URLFORMAT:-%host%}"
PROBE_CURL_DEFAULT_SCHEME="${PROBE_CURL_DEFAULT_SCHEME:-http}"

PROBE_TCPPING_HTTP_BINARY="${PROBE_TCPPING_HTTP_BINARY:-/usr/local/bin/tcpping}"
PROBE_TCPPING_HTTP_FORKS="${PROBE_TCPPING_HTTP_FORKS:-10}"
PROBE_TCPPING_HTTP_OFFSET="${PROBE_TCPPING_HTTP_OFFSET:-random}"
PROBE_TCPPING_HTTP_PINGS="${PROBE_TCPPING_HTTP_PINGS:-30}"
PROBE_TCPPING_HTTP_STEP="${PROBE_TCPPING_HTTP_STEP:-60}"
PROBE_TCPPING_HTTP_PORT="${PROBE_TCPPING_HTTP_PORT:-80}"

PROBE_TCPPING_HTTPS_BINARY="${PROBE_TCPPING_HTTPS_BINARY:-/usr/local/bin/tcpping}"
PROBE_TCPPING_HTTPS_FORKS="${PROBE_TCPPING_HTTPS_FORKS:-10}"
PROBE_TCPPING_HTTPS_OFFSET="${PROBE_TCPPING_HTTPS_OFFSET:-random}"
PROBE_TCPPING_HTTPS_PINGS="${PROBE_TCPPING_HTTPS_PINGS:-30}"
PROBE_TCPPING_HTTPS_STEP="${PROBE_TCPPING_HTTPS_STEP:-60}"
PROBE_TCPPING_HTTPS_PORT="${PROBE_TCPPING_HTTPS_PORT:-443}"

DATABASE_STEP="${DATABASE_STEP:-60}"
DATABASE_PINGS="${DATABASE_PINGS:-100}"

mostrar_ajuda() {
    cat << 'EOF'
Instalador SmokePing

Uso:
  smokeping-install-v31.sh --targets-base64 <base64> [opcoes]
  smokeping-install-v31.sh --targets-json <json> [opcoes]
  smokeping-install-v31.sh --targets-file <arquivo> [opcoes]

Opcoes:
  --targets-base64 <base64>  JSON de categorias/targets em base64.
  --targets-json <json>      JSON bruto com categorias/targets.
  --targets-file <arquivo>   Caminho para arquivo JSON no proxy.
  --prune-missing            Remove RRDs que nao existem mais no JSON.
  --delete-data              Remove todos os RRDs antes de recriar.
  --clean, --clean-install   Recria configuracao e dados do zero.
  -h, --help                 Exibe esta ajuda.
EOF
}

for argumento in "$@"; do
    case "${argumento}" in
        -h|--help)
            mostrar_ajuda
            exit 0
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root."
    exit 1
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --targets-base64)
            if [ -z "${2:-}" ]; then
                echo "Parametro --targets-base64 requer um valor."
                mostrar_ajuda
                exit 1
            fi
            TARGETS_JSON_BASE64="$2"
            shift 2
            ;;
        --targets-json)
            if [ -z "${2:-}" ]; then
                echo "Parametro --targets-json requer um valor."
                mostrar_ajuda
                exit 1
            fi
            TARGETS_JSON_RAW="$2"
            shift 2
            ;;
        --targets-file)
            if [ -z "${2:-}" ]; then
                echo "Parametro --targets-file requer um valor."
                mostrar_ajuda
                exit 1
            fi
            TARGETS_JSON_FILE="$2"
            shift 2
            ;;
        --prune-missing)
            REMOVER_DADOS_ORFAOS="sim"
            shift
            ;;
        --delete-data)
            APAGAR_TODOS_DADOS="sim"
            shift
            ;;
        --clean|--clean-install)
            MODO_INSTALACAO="clean"
            shift
            ;;
        *)
            echo "Parametro desconhecido: $1"
            mostrar_ajuda
            exit 1
            ;;
    esac
done

criar_backup_do_arquivo() {
    local arquivo="$1"
    if [ -f "${arquivo}" ]; then
        local data_hora
        data_hora="$(date +%Y%m%d-%H%M%S)"
        cp -f "${arquivo}" "${arquivo}.bak.${data_hora}"
    fi
}

criar_backup_do_diretorio() {
    local diretorio="$1"
    local destino_base="$2"

    if [ ! -d "${diretorio}" ]; then
        return 0
    fi

    if [ -z "$(ls -A "${diretorio}" 2>/dev/null || true)" ]; then
        return 0
    fi

    local data_hora
    data_hora="$(date +%Y%m%d-%H%M%S)"

    local destino
    destino="${destino_base}.bak.${data_hora}"

    mv -f "${diretorio}" "${destino}"
    mkdir -p "${diretorio}"
}

instalar_docker_se_necessario() {
    if command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y docker.io
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y docker
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y docker
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache docker
        return 0
    fi

    echo "Docker nao encontrado e nao foi possivel instalar automaticamente."
    exit 1
}

garantir_docker_funcionando() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "Docker nao encontrado."
        exit 1
    fi

    if docker info >/dev/null 2>&1; then
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl start docker >/dev/null 2>&1 || true
    fi

    if docker info >/dev/null 2>&1; then
        return 0
    fi

    if command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi

    if docker info >/dev/null 2>&1; then
        return 0
    fi

    echo "Docker instalado, mas o daemon nao esta respondendo."
    exit 1
}

instalar_tcpping_manual() {
    if command -v tcpping >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl nao encontrado para baixar tcpping manualmente."
        return 1
    fi

    curl -fsSL https://raw.githubusercontent.com/deajan/tcpping/master/tcpping -o /usr/local/bin/tcpping
    chmod 0755 /usr/local/bin/tcpping

    if ! command -v tcpping >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

verificar_dependencias_host() {
    local faltando=()

    if ! command -v rrdtool >/dev/null 2>&1; then
        faltando+=("rrdtool")
    fi
    if ! command -v curl >/dev/null 2>&1; then
        faltando+=("curl")
    fi
    if ! command -v fping >/dev/null 2>&1; then
        faltando+=("fping")
    fi
    if ! command -v tcpping >/dev/null 2>&1; then
        faltando+=("tcpping")
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        faltando+=("python3")
    fi

    if [ "${#faltando[@]}" -ne 0 ]; then
        echo "Dependencias ausentes no host: ${faltando[*]}"
        exit 1
    fi
}

instalar_dependencias_host() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y rrdtool curl fping jq perl python3

        if ! command -v tcpping >/dev/null 2>&1; then
            if ! apt-get install -y tcpping; then
                instalar_tcpping_manual || true
            fi
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y rrdtool curl fping jq perl python3

        if ! command -v tcpping >/dev/null 2>&1; then
            dnf install -y tcpping || true
            instalar_tcpping_manual || true
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y rrdtool curl fping jq perl python3

        if ! command -v tcpping >/dev/null 2>&1; then
            yum install -y tcpping || true
            instalar_tcpping_manual || true
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache rrdtool curl fping jq perl python3

        if ! command -v tcpping >/dev/null 2>&1; then
            apk add --no-cache tcpping || true
            instalar_tcpping_manual || true
        fi

        verificar_dependencias_host
        return 0
    fi

    echo "Nao foi possivel instalar dependencias no host (gerenciador de pacotes nao encontrado)."
    exit 1
}

parar_container_se_existir() {
    local nome="$1"

    if docker ps -a --format '{{.Names}}' | grep -Fxq "${nome}"; then
        docker rm -f "${nome}" >/dev/null 2>&1 || true
    fi
}

construir_imagem_smokeping_com_tcpping() {
    docker pull "${IMAGEM_DO_CONTAINER_BASE}" 1>&2

    local diretorio_build
    diretorio_build="$(mktemp -d)"

    local dockerfile
    dockerfile="${diretorio_build}/Dockerfile"

    cat > "${dockerfile}" << EOF
FROM ${IMAGEM_DO_CONTAINER_BASE}
RUN set -e; \\
    if command -v apk >/dev/null 2>&1; then \\
        apk add --no-cache curl bind-tools fping perl; \\
        apk add --no-cache tcpping || true; \\
    elif command -v apt-get >/dev/null 2>&1; then \\
        export DEBIAN_FRONTEND=noninteractive; \\
        apt-get update; \\
        apt-get install -y --no-install-recommends curl dnsutils fping perl; \\
        apt-get install -y --no-install-recommends tcpping || true; \\
        rm -rf /var/lib/apt/lists/*; \\
    else \\
        echo "Gerenciador de pacotes nao suportado na imagem base."; \\
        exit 1; \\
    fi; \\
    if ! command -v tcpping >/dev/null 2>&1; then \\
        curl -fsSL https://raw.githubusercontent.com/deajan/tcpping/master/tcpping -o /usr/local/bin/tcpping; \\
        chmod 0755 /usr/local/bin/tcpping; \\
    fi; \\
    command -v tcpping >/dev/null 2>&1; \\
    tcpping_path="\$(command -v tcpping)"; \\
    if [ -n "\${tcpping_path}" ] && [ "\${tcpping_path}" != "/usr/bin/tcpping" ]; then ln -sf "\${tcpping_path}" /usr/bin/tcpping; fi; \\
    fping_path="\$(command -v fping || true)"; \\
    if [ -n "\${fping_path}" ] && [ "\${fping_path}" != "/usr/sbin/fping" ]; then ln -sf "\${fping_path}" /usr/sbin/fping; fi; \\
    dig_path="\$(command -v dig || true)"; \\
    if [ -n "\${dig_path}" ] && [ "\${dig_path}" != "/usr/bin/dig" ]; then ln -sf "\${dig_path}" /usr/bin/dig; fi; \\
    curl_path="\$(command -v curl || true)"; \\
    if [ -n "\${curl_path}" ] && [ "\${curl_path}" != "/usr/bin/curl" ]; then ln -sf "\${curl_path}" /usr/bin/curl; fi
EOF

    docker build -t "${IMAGEM_DO_CONTAINER}" "${diretorio_build}" 1>&2

    rm -rf "${diretorio_build}" >/dev/null 2>&1 || true

    if ! docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v tcpping >/dev/null 2>&1'; then
        echo "Falha ao garantir tcpping dentro da imagem ${IMAGEM_DO_CONTAINER}."
        echo "Saida de verificacao:"
        docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v tcpping || true; ls -l /usr/bin/tcpping /usr/sbin/tcpping /usr/local/bin/tcpping 2>/dev/null || true'
        exit 1
    fi

}

garantir_imagem_smokeping_disponivel() {
    if docker image inspect "${IMAGEM_DO_CONTAINER}" >/dev/null 2>&1; then
        return 0
    fi

    docker pull "${IMAGEM_DO_CONTAINER}" 1>&2
}

executar_instalacao_limpa_se_solicitada() {
    if [ "${MODO_INSTALACAO}" != "clean" ]; then
        return 0
    fi

    echo "Modo clean habilitado: removendo instalacao anterior em ${DIRETORIO_BASE_PADRAO}."
    parar_container_se_existir "${NOME_DO_CONTAINER_SINCRONIZADOR}"
    parar_container_se_existir "${NOME_DO_CONTAINER}"

    rm -rf "${DIRETORIO_BASE_PADRAO:?}"
}

arquivo_tabela_valido() {
    local arquivo="$1"

    if [ ! -s "${arquivo}" ]; then
        return 1
    fi

    awk '
        BEGIN { ok = 1 }
        /^[[:space:]]*($|#)/ { next }
        /^[[:space:]]*[@+]?include[[:space:]]+/ { next }
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next }
        { ok = 0; exit }
        END { exit (ok ? 0 : 1) }
    ' "${arquivo}"
}

extrair_general_padrao_da_imagem() {
    garantir_imagem_smokeping_disponivel

    local caminho_general
    caminho_general="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'for p in /defaults/smoke-conf/General /root/defaults/smoke-conf/General /usr/share/smokeping/config.d/General /etc/smokeping/config.d/General /etc/smokeping/General; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"

    if [ -z "${caminho_general}" ]; then
        echo "Nao foi possivel localizar o arquivo General padrao na imagem."
        exit 1
    fi

    docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c "cat \"${caminho_general}\"" > "${ARQUIVO_GENERAL}"
    chmod 0644 "${ARQUIVO_GENERAL}"
    chown "${PUID}:${PGID}" "${ARQUIVO_GENERAL}" 2>/dev/null || true
}

extrair_pathnames_padrao_da_imagem() {
    garantir_imagem_smokeping_disponivel

    local caminho_pathnames
    caminho_pathnames="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'for p in /defaults/smoke-conf/pathnames /root/defaults/smoke-conf/pathnames /usr/share/smokeping/config.d/pathnames /etc/smokeping/config.d/pathnames /etc/smokeping/pathnames /defaults/smoke-conf/Pathnames /root/defaults/smoke-conf/Pathnames /usr/share/smokeping/config.d/Pathnames /etc/smokeping/config.d/Pathnames /etc/smokeping/Pathnames; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"

    if [ -z "${caminho_pathnames}" ]; then
        echo "Nao foi possivel localizar o arquivo pathnames padrao na imagem."
        exit 1
    fi

    local arquivo_pathnames
    arquivo_pathnames="${DIRETORIO_CONFIGURACAO}/pathnames"

    docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c "cat \"${caminho_pathnames}\"" > "${arquivo_pathnames}"
    chmod 0644 "${arquivo_pathnames}"
    chown "${PUID}:${PGID}" "${arquivo_pathnames}" 2>/dev/null || true
}

garantir_general_valido() {
    if arquivo_tabela_valido "${ARQUIVO_GENERAL}"; then
        return 0
    fi

    echo "Arquivo General invalido. Recriando a partir do padrao da imagem."
    criar_backup_do_arquivo "${ARQUIVO_GENERAL}"
    extrair_general_padrao_da_imagem
}

instalar_docker_se_necessario
garantir_docker_funcionando
instalar_dependencias_host
construir_imagem_smokeping_com_tcpping

FUSO_HORARIO="${FUSO_HORARIO:-}"
if [ -z "${FUSO_HORARIO}" ]; then
    if [ -f /etc/timezone ]; then
        FUSO_HORARIO="$(cat /etc/timezone || true)"
    fi
fi
if [ -z "${FUSO_HORARIO}" ]; then
    FUSO_HORARIO="Etc/UTC"
fi

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

DIRETORIO_CONFIGURACAO="${DIRETORIO_BASE_PADRAO}/config"
DIRETORIO_DADOS="${DIRETORIO_BASE_PADRAO}/data"
DIRETORIO_SYNC="${DIRETORIO_BASE_PADRAO}/sync"
DIRETORIO_CACHE="${DIRETORIO_BASE_PADRAO}/cache"

executar_instalacao_limpa_se_solicitada

mkdir -p "${DIRETORIO_CONFIGURACAO}"
mkdir -p "${DIRETORIO_DADOS}"
mkdir -p "${DIRETORIO_SYNC}"
mkdir -p "${DIRETORIO_CACHE}"

chown -R "${PUID}:${PGID}" "${DIRETORIO_CONFIGURACAO}" "${DIRETORIO_DADOS}" "${DIRETORIO_SYNC}" "${DIRETORIO_CACHE}" 2>/dev/null || true

ARQUIVO_GENERAL="${DIRETORIO_CONFIGURACAO}/General"
ARQUIVO_PROBES="${DIRETORIO_CONFIGURACAO}/Probes"
ARQUIVO_TARGETS="${DIRETORIO_CONFIGURACAO}/Targets"

DIRETORIO_SITE_CONFS="${DIRETORIO_CONFIGURACAO}/site-confs"
ARQUIVO_HTTPD_CONF="${DIRETORIO_CONFIGURACAO}/httpd.conf"
ARQUIVO_REDIRECIONAMENTO_RAIZ="${DIRETORIO_SITE_CONFS}/00-root-smokeping.conf"

configuracao_padrao_incompleta() {
    local faltando
    faltando="nao"

    if [ ! -f "${DIRETORIO_CONFIGURACAO}/General" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Alerts" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Database" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Presentation" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Probes" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Slaves" ]; then
        faltando="sim"
    fi
    if [ ! -f "${DIRETORIO_CONFIGURACAO}/Targets" ]; then
        faltando="sim"
    fi

    if [ "${faltando}" = "sim" ]; then
        return 0
    fi

    return 1
}

executar_bootstrap_padrao_do_container() {
    garantir_imagem_smokeping_disponivel

    local nome_temporario
    nome_temporario="smokeping-bootstrap-$$"

    local diretorio_dados_temporario
    diretorio_dados_temporario="$(mktemp -d)"

    docker run -d \
        --name="${nome_temporario}" \
        -e PUID="${PUID}" \
        -e PGID="${PGID}" \
        -e TZ="${FUSO_HORARIO}" \
        -v "${DIRETORIO_CONFIGURACAO}:/config" \
        -v "${diretorio_dados_temporario}:/data" \
        -v "${DIRETORIO_CACHE}:/var/cache/smokeping" \
        "${IMAGEM_DO_CONTAINER}" >/dev/null

    local tentativas
    tentativas=0

    while true; do
        if [ -f "${DIRETORIO_CONFIGURACAO}/General" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Alerts" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Database" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Presentation" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Probes" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Slaves" ] \
            && [ -f "${DIRETORIO_CONFIGURACAO}/Targets" ]; then
            break
        fi

        tentativas="$((tentativas + 1))"
        if [ "${tentativas}" -ge 60 ]; then
            echo "Falha ao gerar configuracao padrao dentro de 60 segundos."
            docker logs "${nome_temporario}" || true
            docker rm -f "${nome_temporario}" >/dev/null 2>&1 || true
            rm -rf "${diretorio_dados_temporario}" >/dev/null 2>&1 || true
            exit 1
        fi

        sleep 1
    done

    docker rm -f "${nome_temporario}" >/dev/null 2>&1 || true
    rm -rf "${diretorio_dados_temporario}" >/dev/null 2>&1 || true

    chown -R "${PUID}:${PGID}" "${DIRETORIO_CONFIGURACAO}" 2>/dev/null || true
}

garantir_configuracao_padrao_completa() {
    if configuracao_padrao_incompleta; then
        criar_backup_do_diretorio "${DIRETORIO_CONFIGURACAO}" "${DIRETORIO_CONFIGURACAO}"
        executar_bootstrap_padrao_do_container
    fi
}

forcar_variavel_unica_em_arquivo_smokeping() {
    local arquivo="$1"
    local nome_variavel="$2"
    local valor_variavel="$3"

    if [ ! -f "${arquivo}" ]; then
        echo "Arquivo nao encontrado: ${arquivo}"
        exit 1
    fi

    criar_backup_do_arquivo "${arquivo}"

    local arquivo_temporario
    arquivo_temporario="$(mktemp)"

    awk -v variavel="${nome_variavel}" -v valor="${valor_variavel}" '
        BEGIN {
            escrito = 0
        }

        $0 ~ "^[[:space:]]*" variavel "[[:space:]]*=" {
            if (escrito == 0) {
                print variavel " = " valor
                escrito = 1
            }
            next
        }

        {
            print
        }

        END {
            if (escrito == 0) {
                if (NR > 0) {
                    print ""
                }
                print variavel " = " valor
            }
        }
    ' "${arquivo}" > "${arquivo_temporario}"

    mv -f "${arquivo_temporario}" "${arquivo}"
}

recriar_general_e_forcar_datadir_em_pathnames_se_existir() {
    garantir_general_valido

    local arquivo_general
    arquivo_general="${DIRETORIO_CONFIGURACAO}/General"

    local arquivo_pathnames
    arquivo_pathnames="${DIRETORIO_CONFIGURACAO}/pathnames"

    if [ ! -f "${arquivo_general}" ]; then
        echo "Arquivo General nao encontrado para ajuste: ${arquivo_general}"
        exit 1
    fi

    criar_backup_do_arquivo "${arquivo_general}"

    local arquivo_general_temporario
    arquivo_general_temporario="$(mktemp)"

    awk '
        /^[[:space:]]*datadir[[:space:]]*=/ { next }
        { print }
    ' "${arquivo_general}" > "${arquivo_general_temporario}"

    mv -f "${arquivo_general_temporario}" "${arquivo_general}"
    chmod 0644 "${arquivo_general}"
    chown "${PUID}:${PGID}" "${arquivo_general}" 2>/dev/null || true

    if grep -Eq '^[[:space:]]*@include[[:space:]]+/config/pathnames[[:space:]]*$' "${arquivo_general}"; then
        if [ ! -f "${arquivo_pathnames}" ]; then
            extrair_pathnames_padrao_da_imagem
        fi

        if [ ! -f "${arquivo_pathnames}" ]; then
            echo "Arquivo pathnames nao encontrado: ${arquivo_pathnames}"
            echo "O General inclui /config/pathnames, mas o arquivo nao existe."
            exit 1
        fi

        forcar_variavel_unica_em_arquivo_smokeping "${arquivo_pathnames}" "datadir" "/data"
        chmod 0644 "${arquivo_pathnames}"
        chown "${PUID}:${PGID}" "${arquivo_pathnames}" 2>/dev/null || true
    else
        forcar_variavel_unica_em_arquivo_smokeping "${arquivo_general}" "datadir" "/data"
        chmod 0644 "${arquivo_general}"
        chown "${PUID}:${PGID}" "${arquivo_general}" 2>/dev/null || true
    fi
}

decodificar_base64_para_arquivo() {
    local conteudo="$1"
    local destino="$2"

    if printf '%s' "${conteudo}" | base64 --decode > "${destino}" 2>/dev/null; then
        return 0
    fi

    if printf '%s' "${conteudo}" | base64 -d > "${destino}" 2>/dev/null; then
        return 0
    fi

    echo "Falha ao decodificar base64 do JSON."
    exit 1
}

preparar_arquivo_json_entrada() {
    local entradas=0
    local arquivo_temporario
    arquivo_temporario="$(mktemp)"

    if [ -n "${TARGETS_JSON_BASE64}" ]; then
        entradas="$((entradas + 1))"
    fi
    if [ -n "${TARGETS_JSON_RAW}" ]; then
        entradas="$((entradas + 1))"
    fi
    if [ -n "${TARGETS_JSON_FILE}" ]; then
        entradas="$((entradas + 1))"
    fi

    if [ "${entradas}" -eq 0 ]; then
        echo "Nenhum JSON informado. Use --targets-base64, --targets-json ou --targets-file."
        mostrar_ajuda
        exit 1
    fi

    if [ "${entradas}" -gt 1 ]; then
        echo "Informe apenas uma fonte de JSON (--targets-base64, --targets-json ou --targets-file)."
        mostrar_ajuda
        exit 1
    fi

    if [ -n "${TARGETS_JSON_BASE64}" ]; then
        decodificar_base64_para_arquivo "${TARGETS_JSON_BASE64}" "${arquivo_temporario}"
    elif [ -n "${TARGETS_JSON_RAW}" ]; then
        printf '%s' "${TARGETS_JSON_RAW}" > "${arquivo_temporario}"
    elif [ -n "${TARGETS_JSON_FILE}" ]; then
        if [ ! -f "${TARGETS_JSON_FILE}" ]; then
            echo "Arquivo JSON nao encontrado: ${TARGETS_JSON_FILE}"
            exit 1
        fi
        cp -f "${TARGETS_JSON_FILE}" "${arquivo_temporario}"
    fi

    echo "${arquivo_temporario}"
}

gerar_targets_e_lista() {
    local arquivo_json="$1"
    local arquivo_targets="$2"
    local arquivo_lista="$3"

    PROBE_CURL_DEFAULT_SCHEME="${PROBE_CURL_DEFAULT_SCHEME}" \
    PROBE_CURL_URLFORMAT="${PROBE_CURL_URLFORMAT}" \
    python3 - "${arquivo_json}" "${arquivo_targets}" "${arquivo_lista}" << 'PY'
import json
import os
import re
import sys

json_path, targets_path, list_path = sys.argv[1:4]

def sanitize_name(value):
    value = str(value or "").strip()
    value = re.sub(r"\s+", "_", value)
    value = re.sub(r"[^A-Za-z0-9_-]", "_", value)
    if not value:
        value = "ID_VAZIO"
    if re.match(r"^[0-9]", value):
        value = f"ID_{value}"
    return value

def clean_text(value, fallback):
    text = str(value or "").strip()
    if not text:
        return fallback
    return re.sub(r"[\r\n]+", " ", text)

def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "sim")
    return False

def normalize_categories(raw):
    if isinstance(raw, dict):
        return [(str(k), v) for k, v in raw.items()]
    if isinstance(raw, list):
        categories = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            name = item.get("category") or item.get("name") or item.get("grupo") or item.get("grupo_nome")
            entries = item.get("items") or item.get("targets") or item.get("data") or item.get("values")
            if name is None:
                continue
            categories.append((str(name), entries))
        return categories
    raise ValueError("JSON deve ser um objeto de categorias ou lista de categorias.")

with open(json_path, "r", encoding="utf-8") as handle:
    raw = json.load(handle)

categories = normalize_categories(raw)

probe_order = ["fping", "dns", "curl", "http"]
probe_map = {
    "fping": {"probe": "FPing", "label": "FPing"},
    "dns": {"probe": "DNS", "label": "DNS"},
    "curl": {"probe": "Curl", "label": "Curl"},
    "http": {"probe": "TCPPing", "label": "HTTP"},
}

default_probe = "FPing"
for key in probe_order:
    found = False
    for _, entries in categories:
        if not isinstance(entries, list):
            continue
        if any(truthy(entry.get(key)) for entry in entries if isinstance(entry, dict)):
            default_probe = probe_map[key]["probe"]
            found = True
            break
    if found:
        break

curl_default_scheme = os.environ.get("PROBE_CURL_DEFAULT_SCHEME", "http").strip() or "http"
curl_urlformat = os.environ.get("PROBE_CURL_URLFORMAT", "%host%").strip() or "%host%"

lines = [
    "*** Targets ***",
    "",
    f"probe = {default_probe}",
    "menu = Top",
    "title = SmokePing Targets",
    "",
]

expected = []
seen_groups = {}

def unique_name(base, seen):
    if base not in seen:
        seen[base] = 1
        return base
    seen[base] += 1
    return f"{base}__{seen[base]}"

def has_scheme(value):
    return bool(re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", value))

def iter_entries(entries):
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]

for category_name, entries in sorted(categories, key=lambda item: item[0]):
    group_label = clean_text(category_name, "Grupo")
    group_id = unique_name(sanitize_name(group_label), seen_groups)

    subgroup_lines = []
    expected_group = []

    for probe_key in probe_order:
        filtered = [
            entry for entry in iter_entries(entries)
            if truthy(entry.get(probe_key)) and clean_text(entry.get("host"), "") != ""
        ]
        if not filtered:
            continue

        subgroup_id = sanitize_name(probe_key)
        label = probe_map[probe_key]["label"]
        subgroup_lines.append(f"++ {subgroup_id}")
        subgroup_lines.append(f"menu = {label}")
        subgroup_lines.append(f"title = {label}")
        subgroup_lines.append(f"probe = {probe_map[probe_key]['probe']}")
        if probe_key == "curl":
            subgroup_lines.append(f"urlformat = {curl_urlformat}")
        subgroup_lines.append("")

        seen_targets = {}
        for entry in filtered:
            base_id = entry.get("id") or entry.get("host") or entry.get("menu") or entry.get("title") or "target"
            target_id = unique_name(sanitize_name(base_id), seen_targets)
            menu = clean_text(entry.get("menu"), target_id)
            title = clean_text(entry.get("title"), menu)
            host = clean_text(entry.get("host"), "")
            if probe_key == "curl" and host and not has_scheme(host):
                host = f"{curl_default_scheme}://{host}"

            subgroup_lines.append(f"+++ {target_id}")
            subgroup_lines.append(f"menu = {menu}")
            subgroup_lines.append(f"title = {title}")
            subgroup_lines.append(f"host = {host}")
            subgroup_lines.append("")
            expected_group.append(f"{group_id}/{subgroup_id}/{target_id}.rrd")

    if not subgroup_lines:
        continue

    lines.append(f"+ {group_id}")
    lines.append(f"menu = {group_label}")
    lines.append(f"title = {group_label}")
    lines.append("")
    lines.extend(subgroup_lines)
    expected.extend(expected_group)

with open(targets_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines).rstrip() + "\n")

with open(list_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(sorted(expected)).rstrip() + "\n")
PY
}

recriar_targets_com_json() {
    local arquivo_json="$1"
    local arquivo_lista="$2"
    local arquivo_targets_temporario
    arquivo_targets_temporario="$(mktemp)"

    gerar_targets_e_lista "${arquivo_json}" "${arquivo_targets_temporario}" "${arquivo_lista}"

    criar_backup_do_arquivo "${ARQUIVO_TARGETS}"
    mv -f "${arquivo_targets_temporario}" "${ARQUIVO_TARGETS}"
    chmod 0644 "${ARQUIVO_TARGETS}"
    chown "${PUID}:${PGID}" "${ARQUIVO_TARGETS}" 2>/dev/null || true
}

apagar_todos_os_rrd() {
    if [ "${APAGAR_TODOS_DADOS}" != "sim" ]; then
        return 0
    fi

    if [ -d "${DIRETORIO_DADOS}" ]; then
        find "${DIRETORIO_DADOS}" -mindepth 1 -exec rm -rf {} +
        mkdir -p "${DIRETORIO_DADOS}"
        chown -R "${PUID}:${PGID}" "${DIRETORIO_DADOS}" 2>/dev/null || true
    fi
}

remover_dados_orfaos() {
    local arquivo_lista="$1"

    if [ "${REMOVER_DADOS_ORFAOS}" != "sim" ]; then
        return 0
    fi

    if [ ! -d "${DIRETORIO_DADOS}" ]; then
        return 0
    fi

    if [ ! -s "${arquivo_lista}" ]; then
        return 0
    fi

    while IFS= read -r arquivo_rrd; do
        if [ -z "${arquivo_rrd}" ]; then
            continue
        fi
        if ! grep -Fxq "${arquivo_rrd}" "${arquivo_lista}"; then
            rm -f "${DIRETORIO_DADOS}/${arquivo_rrd}" || true
        fi
    done < <(find "${DIRETORIO_DADOS}" -type f -name '*.rrd' -printf '%P\n')

    find "${DIRETORIO_DADOS}" -mindepth 1 -type d -empty -delete
}

recriar_arquivo_probes_com_parametros_desejados() {
    criar_backup_do_arquivo "${ARQUIVO_PROBES}"

    cat > "${ARQUIVO_PROBES}" << EOF
*** Probes ***

+ FPing
binary = ${PROBE_FPING_BINARY}
pings = ${PROBE_FPING_PINGS}
step = ${PROBE_FPING_STEP}
hostinterval = ${PROBE_FPING_HOSTINTERVAL}
timeout = ${PROBE_FPING_TIMEOUT}

+ DNS
binary = ${PROBE_DNS_BINARY}
lookup = ${PROBE_DNS_LOOKUP}
pings = ${PROBE_DNS_PINGS}
step = ${PROBE_DNS_STEP}
timeout = ${PROBE_DNS_TIMEOUT}

+ Curl
binary = ${PROBE_CURL_BINARY}
forks = ${PROBE_CURL_FORKS}
offset = ${PROBE_CURL_OFFSET}
step = ${PROBE_CURL_STEP}
pings = ${PROBE_CURL_PINGS}
extraargs = ${PROBE_CURL_EXTRAARGS}

+ TCPPing
binary = ${PROBE_TCPPING_HTTP_BINARY}
forks = ${PROBE_TCPPING_HTTP_FORKS}
offset = ${PROBE_TCPPING_HTTP_OFFSET}
pings = ${PROBE_TCPPING_HTTP_PINGS}
step = ${PROBE_TCPPING_HTTP_STEP}
port = ${PROBE_TCPPING_HTTP_PORT}
EOF

    chmod 0644 "${ARQUIVO_PROBES}"
    chown "${PUID}:${PGID}" "${ARQUIVO_PROBES}" 2>/dev/null || true
}

recriar_arquivo_database_com_parametros_desejados() {
    local arquivo_database
    arquivo_database="${DIRETORIO_CONFIGURACAO}/Database"

    criar_backup_do_arquivo "${arquivo_database}"

    cat > "${arquivo_database}" << EOF
*** Database ***

step     = ${DATABASE_STEP}
pings    = ${DATABASE_PINGS}

# consfn mrhb steps total

AVERAGE  0.5   1  1008
AVERAGE  0.5  12  4320
    MIN  0.5  12  4320
    MAX  0.5  12  4320
AVERAGE  0.5 144   720
    MAX  0.5 144   720
    MIN  0.5 144   720
EOF

    chmod 0644 "${arquivo_database}"
    chown "${PUID}:${PGID}" "${arquivo_database}" 2>/dev/null || true
}

criar_redirecionamento_para_raiz() {
    mkdir -p "${DIRETORIO_SITE_CONFS}"

    criar_backup_do_arquivo "${ARQUIVO_REDIRECIONAMENTO_RAIZ}"

    cat > "${ARQUIVO_REDIRECIONAMENTO_RAIZ}" << 'EOF'
RedirectMatch 302 ^/$ /smokeping/smokeping.cgi
EOF

    chmod 0644 "${ARQUIVO_REDIRECIONAMENTO_RAIZ}"
    chown "${PUID}:${PGID}" "${ARQUIVO_REDIRECIONAMENTO_RAIZ}" 2>/dev/null || true

    if [ -f "${ARQUIVO_HTTPD_CONF}" ]; then
        if ! grep -q 'IncludeOptional /config/site-confs/\*\.conf' "${ARQUIVO_HTTPD_CONF}"; then
            criar_backup_do_arquivo "${ARQUIVO_HTTPD_CONF}"
            {
                echo ""
                echo "# Auto-gerado para carregar arquivos em /config/site-confs"
                echo "IncludeOptional /config/site-confs/*.conf"
                echo ""
            } >> "${ARQUIVO_HTTPD_CONF}"
        fi
    fi
}

validar_configuracao_smokeping() {
    garantir_imagem_smokeping_disponivel

    docker run --rm \
        -v "${DIRETORIO_CONFIGURACAO}:/config" \
        -v "${DIRETORIO_DADOS}:/data" \
        -v "${DIRETORIO_CACHE}:/var/cache/smokeping" \
        --entrypoint /bin/sh \
        "${IMAGEM_DO_CONTAINER}" \
        -c '
            set -e
            if command -v smokeping >/dev/null 2>&1; then
                smokeping --check /etc/smokeping/config
                exit 0
            fi
            if [ -x /usr/sbin/smokeping ]; then
                /usr/sbin/smokeping --check /etc/smokeping/config
                exit 0
            fi
            echo "Binario smokeping nao encontrado para validacao."
            exit 1
        '
}

iniciar_ou_recriar_container_smokeping() {
    parar_container_se_existir "${NOME_DO_CONTAINER}"

    garantir_imagem_smokeping_disponivel

    docker run -d \
        --name="${NOME_DO_CONTAINER}" \
        -e PUID="${PUID}" \
        -e PGID="${PGID}" \
        -e TZ="${FUSO_HORARIO}" \
        -p "${PORTA_HTTP_NO_HOST}:80" \
        -v "${DIRETORIO_CONFIGURACAO}:/config" \
        -v "${DIRETORIO_DADOS}:/data" \
        -v "${DIRETORIO_CACHE}:/var/cache/smokeping" \
        --restart unless-stopped \
        "${IMAGEM_DO_CONTAINER}"
}

criar_arquivos_do_sincronizador() {
    local arquivo_configuracao_sincronizacao
    arquivo_configuracao_sincronizacao="${DIRETORIO_SYNC}/smokeping-sync.conf"

    cat > "${arquivo_configuracao_sincronizacao}" << EOF
CONTAINER_NAME="${NOME_DO_CONTAINER}"
TARGETS_FILE="/config/Targets"
TARGETS_JSON_FILE="/sync/smokeping-targets.json"
PROBE_CURL_DEFAULT_SCHEME="${PROBE_CURL_DEFAULT_SCHEME}"
PROBE_CURL_URLFORMAT="${PROBE_CURL_URLFORMAT}"
EOF

    chmod 0644 "${arquivo_configuracao_sincronizacao}"
    chown "${PUID}:${PGID}" "${arquivo_configuracao_sincronizacao}" 2>/dev/null || true

    local arquivo_sincronizador
    arquivo_sincronizador="${DIRETORIO_SYNC}/smokeping-sync-targets.sh"

    cat > "${arquivo_sincronizador}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

ARQUIVO_CONFIGURACAO="/sync/smokeping-sync.conf"
if [ ! -f "${ARQUIVO_CONFIGURACAO}" ]; then
    echo "Arquivo de configuracao nao encontrado: ${ARQUIVO_CONFIGURACAO}"
    exit 1
fi

# shellcheck disable=SC1091
. "${ARQUIVO_CONFIGURACAO}"

if [ -z "${CONTAINER_NAME:-}" ]; then
    echo "CONTAINER_NAME nao definido."
    exit 1
fi

if [ -z "${TARGETS_FILE:-}" ]; then
    echo "TARGETS_FILE nao definido."
    exit 1
fi

if [ -z "${TARGETS_JSON_FILE:-}" ] || [ ! -f "${TARGETS_JSON_FILE}" ]; then
    echo "TARGETS_JSON_FILE nao encontrado."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 nao encontrado."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "docker nao encontrado."
    exit 1
fi

TARGETS_TMP="$(mktemp)"

PROBE_CURL_DEFAULT_SCHEME="${PROBE_CURL_DEFAULT_SCHEME}" \
PROBE_CURL_URLFORMAT="${PROBE_CURL_URLFORMAT}" \
python3 - "${TARGETS_JSON_FILE}" "${TARGETS_TMP}" << 'PY'
import json
import os
import re
import sys

json_path, targets_path = sys.argv[1:3]

def sanitize_name(value):
    value = str(value or "").strip()
    value = re.sub(r"\s+", "_", value)
    value = re.sub(r"[^A-Za-z0-9_-]", "_", value)
    if not value:
        value = "ID_VAZIO"
    if re.match(r"^[0-9]", value):
        value = f"ID_{value}"
    return value

def clean_text(value, fallback):
    text = str(value or "").strip()
    if not text:
        return fallback
    return re.sub(r"[\r\n]+", " ", text)

def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y", "sim")
    return False

def normalize_categories(raw):
    if isinstance(raw, dict):
        return [(str(k), v) for k, v in raw.items()]
    if isinstance(raw, list):
        categories = []
        for item in raw:
            if not isinstance(item, dict):
                continue
            name = item.get("category") or item.get("name") or item.get("grupo") or item.get("grupo_nome")
            entries = item.get("items") or item.get("targets") or item.get("data") or item.get("values")
            if name is None:
                continue
            categories.append((str(name), entries))
        return categories
    raise ValueError("JSON deve ser um objeto de categorias ou lista de categorias.")

with open(json_path, "r", encoding="utf-8") as handle:
    raw = json.load(handle)

categories = normalize_categories(raw)

probe_order = ["fping", "dns", "curl", "http"]
probe_map = {
    "fping": {"probe": "FPing", "label": "FPing"},
    "dns": {"probe": "DNS", "label": "DNS"},
    "curl": {"probe": "Curl", "label": "Curl"},
    "http": {"probe": "TCPPing", "label": "HTTP"},
}

default_probe = "FPing"
for key in probe_order:
    found = False
    for _, entries in categories:
        if not isinstance(entries, list):
            continue
        if any(truthy(entry.get(key)) for entry in entries if isinstance(entry, dict)):
            default_probe = probe_map[key]["probe"]
            found = True
            break
    if found:
        break

curl_default_scheme = os.environ.get("PROBE_CURL_DEFAULT_SCHEME", "http").strip() or "http"
curl_urlformat = os.environ.get("PROBE_CURL_URLFORMAT", "%host%").strip() or "%host%"

lines = [
    "*** Targets ***",
    "",
    f"probe = {default_probe}",
    "menu = Top",
    "title = SmokePing Targets",
    "",
]

seen_groups = {}

def unique_name(base, seen):
    if base not in seen:
        seen[base] = 1
        return base
    seen[base] += 1
    return f"{base}__{seen[base]}"

def has_scheme(value):
    return bool(re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://", value))

def iter_entries(entries):
    if not isinstance(entries, list):
        return []
    return [entry for entry in entries if isinstance(entry, dict)]

for category_name, entries in sorted(categories, key=lambda item: item[0]):
    group_label = clean_text(category_name, "Grupo")
    group_id = unique_name(sanitize_name(group_label), seen_groups)

    subgroup_lines = []

    for probe_key in probe_order:
        filtered = [
            entry for entry in iter_entries(entries)
            if truthy(entry.get(probe_key)) and clean_text(entry.get("host"), "") != ""
        ]
        if not filtered:
            continue

        subgroup_id = sanitize_name(probe_key)
        label = probe_map[probe_key]["label"]
        subgroup_lines.append(f"++ {subgroup_id}")
        subgroup_lines.append(f"menu = {label}")
        subgroup_lines.append(f"title = {label}")
        subgroup_lines.append(f"probe = {probe_map[probe_key]['probe']}")
        if probe_key == "curl":
            subgroup_lines.append(f"urlformat = {curl_urlformat}")
        subgroup_lines.append("")

        seen_targets = {}
        for entry in filtered:
            base_id = entry.get("id") or entry.get("host") or entry.get("menu") or entry.get("title") or "target"
            target_id = unique_name(sanitize_name(base_id), seen_targets)
            menu = clean_text(entry.get("menu"), target_id)
            title = clean_text(entry.get("title"), menu)
            host = clean_text(entry.get("host"), "")
            if probe_key == "curl" and host and not has_scheme(host):
                host = f"{curl_default_scheme}://{host}"

            subgroup_lines.append(f"+++ {target_id}")
            subgroup_lines.append(f"menu = {menu}")
            subgroup_lines.append(f"title = {title}")
            subgroup_lines.append(f"host = {host}")
            subgroup_lines.append("")

    if not subgroup_lines:
        continue

    lines.append(f"+ {group_id}")
    lines.append(f"menu = {group_label}")
    lines.append(f"title = {group_label}")
    lines.append("")
    lines.extend(subgroup_lines)

with open(targets_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines).rstrip() + "\n")
PY

if [ ! -f "${TARGETS_FILE}" ] || ! cmp -s "${TARGETS_FILE}" "${TARGETS_TMP}"; then
    if [ -f "${TARGETS_FILE}" ]; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
    fi
    mv -f "${TARGETS_TMP}" "${TARGETS_FILE}"
    chmod 0644 "${TARGETS_FILE}"
    if docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
        docker exec "${CONTAINER_NAME}" pkill -f -HUP '/usr/bin/perl /usr/s?bin/smokeping(_cgi)?' || true
    fi
else
    rm -f "${TARGETS_TMP}"
fi
EOF

    chmod 0755 "${arquivo_sincronizador}"
    chown "${PUID}:${PGID}" "${arquivo_sincronizador}" 2>/dev/null || true
}

iniciar_container_sincronizador() {
    parar_container_se_existir "${NOME_DO_CONTAINER_SINCRONIZADOR}"

    docker pull "${IMAGEM_DO_CONTAINER_SINCRONIZADOR}" 1>&2

    docker run -d \
        --name="${NOME_DO_CONTAINER_SINCRONIZADOR}" \
        -e INTERVALO_SINCRONIZACAO_EM_MINUTOS="${INTERVALO_SINCRONIZACAO_EM_MINUTOS}" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${DIRETORIO_CONFIGURACAO}:/config" \
        -v "${DIRETORIO_DADOS}:/data" \
        -v "${DIRETORIO_SYNC}:/sync" \
        --restart unless-stopped \
        "${IMAGEM_DO_CONTAINER_SINCRONIZADOR}" \
        sh -c 'apk add --no-cache bash python3 >/dev/null 2>&1 || true; while true; do /sync/smokeping-sync-targets.sh || true; sleep "$((INTERVALO_SINCRONIZACAO_EM_MINUTOS * 60))"; done'
}

parar_container_se_existir "${NOME_DO_CONTAINER_SINCRONIZADOR}"
parar_container_se_existir "${NOME_DO_CONTAINER}"

garantir_configuracao_padrao_completa
recriar_arquivo_probes_com_parametros_desejados
recriar_arquivo_database_com_parametros_desejados
recriar_general_e_forcar_datadir_em_pathnames_se_existir
criar_redirecionamento_para_raiz

ARQUIVO_JSON_TEMPORARIO="$(preparar_arquivo_json_entrada)"
ARQUIVO_LISTA_TEMPORARIO="$(mktemp)"
recriar_targets_com_json "${ARQUIVO_JSON_TEMPORARIO}" "${ARQUIVO_LISTA_TEMPORARIO}"

mkdir -p "${DIRETORIO_SYNC}"
cp -f "${ARQUIVO_JSON_TEMPORARIO}" "${DIRETORIO_SYNC}/smokeping-targets.json"
chmod 0644 "${DIRETORIO_SYNC}/smokeping-targets.json"
chown "${PUID}:${PGID}" "${DIRETORIO_SYNC}/smokeping-targets.json" 2>/dev/null || true
rm -f "${ARQUIVO_JSON_TEMPORARIO}"

apagar_todos_os_rrd
remover_dados_orfaos "${ARQUIVO_LISTA_TEMPORARIO}"
rm -f "${ARQUIVO_LISTA_TEMPORARIO}"

criar_arquivos_do_sincronizador

validar_configuracao_smokeping

iniciar_ou_recriar_container_smokeping
iniciar_container_sincronizador

docker exec "${NOME_DO_CONTAINER_SINCRONIZADOR}" /bin/sh -c 'apk add --no-cache bash python3 >/dev/null 2>&1 || true; /sync/smokeping-sync-targets.sh || true' >/dev/null 2>&1 || true

echo ""
echo "Instalacao concluida."
echo ""
echo "Acesso no endereco raiz:"
echo "  http://ENDERECO_DO_SERVIDOR:${PORTA_HTTP_NO_HOST}"
echo ""
echo "Diretorio de configuracao:"
echo "  ${DIRETORIO_CONFIGURACAO}"
echo ""
echo "Diretorio de dados:"
echo "  ${DIRETORIO_DADOS}"
echo ""
echo "Diretorio de cache:"
echo "  ${DIRETORIO_CACHE}"
echo ""
echo "Diretorio do sincronizador:"
echo "  ${DIRETORIO_SYNC}"
echo ""
