#!/usr/bin/env bash
set -euo pipefail

NOME_DO_CONTAINER="${NOME_DO_CONTAINER:-smokeping}"
IMAGEM_DO_CONTAINER_BASE="${IMAGEM_DO_CONTAINER_BASE:-lscr.io/linuxserver/smokeping:latest}"
IMAGEM_DO_CONTAINER="${IMAGEM_DO_CONTAINER:-inoc-smokeping:latest}"
PORTA_HTTP_NO_HOST="${PORTA_HTTP_NO_HOST:-8080}"

NOME_DO_CONTAINER_SINCRONIZADOR="${NOME_DO_CONTAINER_SINCRONIZADOR:-smokeping-sync}"
IMAGEM_DO_CONTAINER_SINCRONIZADOR="${IMAGEM_DO_CONTAINER_SINCRONIZADOR:-docker:cli}"

ENDERECO_JSON_GAMES="${ENDERECO_JSON_GAMES:-https://inocmon-database-dev-default-rtdb.firebaseio.com/public/smokeping/games.json}"
NOME_DO_GRUPO_GAMES="${NOME_DO_GRUPO_GAMES:-games}"

ENDERECO_JSON_DNS_IPV4="${ENDERECO_JSON_DNS_IPV4:-https://inocmon-database-dev-default-rtdb.firebaseio.com/public/smokeping/dns/ipv4.json}"
NOME_DO_GRUPO_DNS_IPV4="${NOME_DO_GRUPO_DNS_IPV4:-dns_ipv4}"
CONSULTA_DNS_IPV4="${CONSULTA_DNS_IPV4:-google.com}"

ENDERECO_JSON_HTTP_IPV4="${ENDERECO_JSON_HTTP_IPV4:-https://inocmon-database-dev-default-rtdb.firebaseio.com/public/smokeping/http/ipv4.json}"
NOME_DO_GRUPO_HTTP_IPV4="${NOME_DO_GRUPO_HTTP_IPV4:-http_ipv4}"
ESQUEMA_PADRAO_HTTP_IPV4="${ESQUEMA_PADRAO_HTTP_IPV4:-http}"
FORMATO_URL_HTTP_IPV4="${FORMATO_URL_HTTP_IPV4:-%host%}"

ENDERECO_JSON_TCPPING_IPV4="${ENDERECO_JSON_TCPPING_IPV4:-https://inocmon-database-dev-default-rtdb.firebaseio.com/public/smokeping/tcpping/ipv4.json}"
NOME_DO_GRUPO_TCPPING_IPV4="${NOME_DO_GRUPO_TCPPING_IPV4:-tcpping_ipv4}"
PORTA_PADRAO_TCPPING_IPV4="${PORTA_PADRAO_TCPPING_IPV4:-80}"

INTERVALO_SINCRONIZACAO_EM_MINUTOS="${INTERVALO_SINCRONIZACAO_EM_MINUTOS:-5}"
DIRETORIO_BASE_PADRAO="${DIRETORIO_BASE_PADRAO:-/opt/smokeping}"
MODO_INSTALACAO="${MODO_INSTALACAO:-update}"

PINGS_FPING_DESEJADO="${PINGS_FPING_DESEJADO:-100}"
STEP_FPING_DESEJADO="${STEP_FPING_DESEJADO:-300}"

BIN_FPING=""
BIN_DIG=""
BIN_TCPPING=""
BIN_CURL=""

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root."
    exit 1
fi

for argumento in "$@"; do
    case "${argumento}" in
        --clean|--clean-install)
            MODO_INSTALACAO="clean"
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

    if [ "${#faltando[@]}" -ne 0 ]; then
        echo "Dependencias ausentes no host: ${faltando[*]}"
        exit 1
    fi
}

instalar_dependencias_host() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y rrdtool curl fping jq perl

        if ! command -v tcpping >/dev/null 2>&1; then
            if ! apt-get install -y tcpping; then
                instalar_tcpping_manual || true
            fi
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y rrdtool curl fping jq perl

        if ! command -v tcpping >/dev/null 2>&1; then
            dnf install -y tcpping || true
            instalar_tcpping_manual || true
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y rrdtool curl fping jq perl

        if ! command -v tcpping >/dev/null 2>&1; then
            yum install -y tcpping || true
            instalar_tcpping_manual || true
        fi

        verificar_dependencias_host
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache rrdtool curl fping jq perl

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

definir_caminhos_binarios_no_container() {
    BIN_FPING="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v fping || true' | head -n 1)"
    BIN_DIG="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v dig || true' | head -n 1)"
    BIN_TCPPING="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v tcpping || true' | head -n 1)"
    BIN_CURL="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'command -v curl || true' | head -n 1)"

    if [ -z "${BIN_FPING}" ]; then
        echo "Nao foi possivel localizar o binario fping dentro da imagem ${IMAGEM_DO_CONTAINER}."
        exit 1
    fi

    if [ -z "${BIN_DIG}" ]; then
        echo "Nao foi possivel localizar o binario dig dentro da imagem ${IMAGEM_DO_CONTAINER}."
        exit 1
    fi

    if [ -z "${BIN_TCPPING}" ]; then
        echo "Nao foi possivel localizar o binario tcpping dentro da imagem ${IMAGEM_DO_CONTAINER}."
        exit 1
    fi

    if [ -z "${BIN_CURL}" ]; then
        echo "Nao foi possivel localizar o binario curl dentro da imagem ${IMAGEM_DO_CONTAINER}."
        exit 1
    fi
}

instalar_docker_se_necessario
garantir_docker_funcionando
instalar_dependencias_host
construir_imagem_smokeping_com_tcpping
definir_caminhos_binarios_no_container

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

resetar_targets_para_grupos_dinamicos() {
    criar_backup_do_arquivo "${ARQUIVO_TARGETS}"
    local probe_padrao
    probe_padrao="$(definir_probe_padrao_targets || true)"

    if [ -z "${probe_padrao}" ]; then
        echo "Nenhum grupo habilitado para definir probe padrao no Targets."
        exit 1
    fi
    {
        echo "*** Targets ***"
        echo ""
        echo "probe = ${probe_padrao}"
        echo "menu = Top"
        echo "title = SmokePing Targets"
        echo ""
    } > "${ARQUIVO_TARGETS}"
    chmod 0644 "${ARQUIVO_TARGETS}"
    chown "${PUID}:${PGID}" "${ARQUIVO_TARGETS}" 2>/dev/null || true
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

obter_valor_no_bloco_probe() {
    local arquivo="$1"
    local nome_probe="$2"
    local nome_variavel="$3"

    if [ ! -f "${arquivo}" ]; then
        return 0
    fi

    awk -v nome="${nome_probe}" -v variavel="${nome_variavel}" '
        BEGIN {
            dentro = 0
        }
        $0 ~ "^\\+[[:space:]]+" nome "[[:space:]]*$" {
            dentro = 1
            next
        }
        dentro == 1 && $0 ~ "^\\+[[:space:]]+" {
            dentro = 0
        }
        dentro == 1 && $0 ~ "^[[:space:]]*" variavel "[[:space:]]*=" {
            linha = $0
            sub("^[[:space:]]*" variavel "[[:space:]]*=[[:space:]]*", "", linha)
            sub("[[:space:]]*$", "", linha)
            print linha
            exit 0
        }
    ' "${arquivo}"
}

grupo_habilitado() {
    local url="$1"
    local nome="$2"

    if [ -n "${url}" ] && [ -n "${nome}" ]; then
        return 0
    fi
    return 1
}

definir_probe_padrao_targets() {
    if grupo_habilitado "${ENDERECO_JSON_GAMES}" "${NOME_DO_GRUPO_GAMES}"; then
        echo "FPing"
        return 0
    fi

    if grupo_habilitado "${ENDERECO_JSON_DNS_IPV4}" "${NOME_DO_GRUPO_DNS_IPV4}"; then
        echo "DNS"
        return 0
    fi

    if grupo_habilitado "${ENDERECO_JSON_HTTP_IPV4}" "${NOME_DO_GRUPO_HTTP_IPV4}"; then
        echo "Curl"
        return 0
    fi

    if grupo_habilitado "${ENDERECO_JSON_TCPPING_IPV4}" "${NOME_DO_GRUPO_TCPPING_IPV4}"; then
        echo "TCPPing"
        return 0
    fi

    echo ""
    return 1
}

tratar_mudanca_de_pings_e_step_se_necessario() {
    if ! grupo_habilitado "${ENDERECO_JSON_GAMES}" "${NOME_DO_GRUPO_GAMES}"; then
        return 0
    fi

    local pings_atual_fping
    local step_atual_fping

    pings_atual_fping="$(obter_valor_no_bloco_probe "${ARQUIVO_PROBES}" "FPing" "pings" || true)"
    step_atual_fping="$(obter_valor_no_bloco_probe "${ARQUIVO_PROBES}" "FPing" "step" || true)"

    local precisa_recriar_dados
    precisa_recriar_dados="nao"

    if [ "${pings_atual_fping:-}" != "${PINGS_FPING_DESEJADO}" ]; then
        precisa_recriar_dados="sim"
    fi

    if [ "${step_atual_fping:-}" != "${STEP_FPING_DESEJADO}" ]; then
        precisa_recriar_dados="sim"
    fi

    if [ "${precisa_recriar_dados}" = "sim" ]; then
        if [ -d "${DIRETORIO_DADOS}" ] && [ -n "$(ls -A "${DIRETORIO_DADOS}" 2>/dev/null || true)" ]; then
            criar_backup_do_diretorio "${DIRETORIO_DADOS}" "${DIRETORIO_DADOS}"
            chown -R "${PUID}:${PGID}" "${DIRETORIO_DADOS}" 2>/dev/null || true
        fi
    fi
}

recriar_arquivo_probes_com_parametros_desejados() {
    criar_backup_do_arquivo "${ARQUIVO_PROBES}"

    {
        echo "*** Probes ***"
        echo ""

        if grupo_habilitado "${ENDERECO_JSON_GAMES}" "${NOME_DO_GRUPO_GAMES}"; then
            echo "+ FPing"
            echo "binary = ${BIN_FPING}"
            echo "pings = ${PINGS_FPING_DESEJADO}"
            echo "step = ${STEP_FPING_DESEJADO}"
            echo ""
        fi

        if grupo_habilitado "${ENDERECO_JSON_DNS_IPV4}" "${NOME_DO_GRUPO_DNS_IPV4}"; then
            echo "+ DNS"
            echo "binary = ${BIN_DIG}"
            echo "lookup = ${CONSULTA_DNS_IPV4}"
            echo "pings = 5"
            echo "step = 300"
            echo ""
        fi

        if grupo_habilitado "${ENDERECO_JSON_HTTP_IPV4}" "${NOME_DO_GRUPO_HTTP_IPV4}"; then
            echo "+ Curl"
            echo "binary = ${BIN_CURL}"
            echo "forks = 2"
            echo "offset = 50%"
            echo "step = 300"
            echo "pings = 3"
            echo "extraargs = -o /dev/null -sS"
            echo ""
        fi

        if grupo_habilitado "${ENDERECO_JSON_TCPPING_IPV4}" "${NOME_DO_GRUPO_TCPPING_IPV4}"; then
            echo "+ TCPPing"
            echo "binary = ${BIN_TCPPING}"
            echo "forks = 10"
            echo "offset = random"
            echo "pings = 5"
            echo "port = ${PORTA_PADRAO_TCPPING_IPV4}"
            echo ""
        fi
    } > "${ARQUIVO_PROBES}"

    chmod 0644 "${ARQUIVO_PROBES}"
    chown "${PUID}:${PGID}" "${ARQUIVO_PROBES}" 2>/dev/null || true
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
    arquivo_configuracao_sincronizacao="${DIRETORIO_SYNC}/smokeping-games-sync.conf"

    cat > "${arquivo_configuracao_sincronizacao}" << EOF
CONTAINER_NAME="${NOME_DO_CONTAINER}"
TARGETS_FILE="/config/Targets"

GAMES_JSON_URL="${ENDERECO_JSON_GAMES}"
GAMES_GROUP_NAME="${NOME_DO_GRUPO_GAMES}"

DNS_IPV4_JSON_URL="${ENDERECO_JSON_DNS_IPV4}"
DNS_IPV4_GROUP_NAME="${NOME_DO_GRUPO_DNS_IPV4}"
DNS_IPV4_LOOKUP="${CONSULTA_DNS_IPV4}"

HTTP_IPV4_JSON_URL="${ENDERECO_JSON_HTTP_IPV4}"
HTTP_IPV4_GROUP_NAME="${NOME_DO_GRUPO_HTTP_IPV4}"
HTTP_IPV4_DEFAULT_SCHEME="${ESQUEMA_PADRAO_HTTP_IPV4}"
HTTP_IPV4_URLFORMAT="${FORMATO_URL_HTTP_IPV4}"

TCPPING_IPV4_JSON_URL="${ENDERECO_JSON_TCPPING_IPV4}"
TCPPING_IPV4_GROUP_NAME="${NOME_DO_GRUPO_TCPPING_IPV4}"
TCPPING_IPV4_DEFAULT_PORT="${PORTA_PADRAO_TCPPING_IPV4}"
EOF

    chmod 0644 "${arquivo_configuracao_sincronizacao}"
    chown "${PUID}:${PGID}" "${arquivo_configuracao_sincronizacao}" 2>/dev/null || true

    local arquivo_sincronizador
    arquivo_sincronizador="${DIRETORIO_SYNC}/smokeping-sync-games-targets.sh"

    cat > "${arquivo_sincronizador}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

ARQUIVO_CONFIGURACAO_SINCRONIZACAO="/sync/smokeping-games-sync.conf"
if [ ! -f "${ARQUIVO_CONFIGURACAO_SINCRONIZACAO}" ]; then
    echo "Arquivo de configuracao nao encontrado: ${ARQUIVO_CONFIGURACAO_SINCRONIZACAO}"
    exit 1
fi

# shellcheck disable=SC1091
. "${ARQUIVO_CONFIGURACAO_SINCRONIZACAO}"

if [ -z "${CONTAINER_NAME:-}" ]; then
    echo "CONTAINER_NAME nao definido."
    exit 1
fi

if [ -z "${TARGETS_FILE:-}" ]; then
    echo "TARGETS_FILE nao definido."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl nao encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq nao encontrado."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "docker nao encontrado."
    exit 1
fi

sanitizar_nome() {
    local valor_original="$1"
    local valor_sanitizado=""

    valor_sanitizado="$(printf '%s' "${valor_original}" | sed 's/[[:space:]]\+/_/g; s/[^A-Za-z0-9_-]/_/g')"

    if [ -z "${valor_sanitizado}" ]; then
        valor_sanitizado="ID_VAZIO"
    fi

    if printf '%s' "${valor_sanitizado}" | grep -Eq '^[0-9]'; then
        valor_sanitizado="ID_${valor_sanitizado}"
    fi

    printf '%s' "${valor_sanitizado}"
}

transformar_host_para_curl_url() {
    local host_original="$1"
    local esquema_padrao="$2"

    if printf '%s' "${host_original}" | grep -Eq '^[A-Za-z][A-Za-z0-9+.-]*://'; then
        printf '%s' "${host_original}"
        return 0
    fi

    if [ -z "${esquema_padrao}" ]; then
        esquema_padrao="http"
    fi

    printf '%s://%s' "${esquema_padrao}" "${host_original}"
}

baixar_json_para_arquivo() {
    local endereco="$1"
    local arquivo_destino="$2"

    curl -fsSL "${endereco}" -o "${arquivo_destino}"

    local tipo_json
    tipo_json="$(jq -r 'type' "${arquivo_destino}")"

    if [ "${tipo_json}" = "null" ]; then
        echo '[]' > "${arquivo_destino}"
        return 0
    fi

    if [ "${tipo_json}" != "array" ]; then
        echo "JSON nao e um array. Tipo encontrado: ${tipo_json}"
        exit 1
    fi
}

gerar_bloco_targets() {
    local nome_do_grupo="$1"
    local menu_do_grupo="$2"
    local titulo_do_grupo="$3"
    local nome_do_probe="$4"
    local linha_extra_do_grupo_1="$5"
    local linha_extra_do_grupo_2="$6"
    local modo_de_alvo="$7"
    local esquema_padrao_para_curl="$8"
    local arquivo_json="$9"
    local arquivo_bloco="${10}"
    local arquivo_lista="${11:-}"

    local marcador_inicio
    local marcador_fim

    marcador_inicio="# BEGIN AUTO-GENERATED TARGETS GROUP: ${nome_do_grupo}"
    marcador_fim="# END AUTO-GENERATED TARGETS GROUP: ${nome_do_grupo}"

    {
        echo "${marcador_inicio}"
        echo ""
        echo "+ ${nome_do_grupo}"
        echo "menu = ${menu_do_grupo}"
        echo "title = ${titulo_do_grupo}"
        echo "probe = ${nome_do_probe}"

        if [ -n "${linha_extra_do_grupo_1}" ]; then
            echo "${linha_extra_do_grupo_1}"
        fi

        if [ -n "${linha_extra_do_grupo_2}" ]; then
            echo "${linha_extra_do_grupo_2}"
        fi

        echo ""

        if [ -n "${arquivo_lista}" ]; then
            : > "${arquivo_lista}"
        fi

        declare -A vistos

        jq -r '.[] | "\((.id // ""))\u001f\((.menu // ""))\u001f\((.title // ""))\u001f\((.host // ""))\u001f\((.port // ""))"' "${arquivo_json}" \
        | while IFS=$'\x1f' read -r id menu title host port; do
            if [ -z "${id}" ]; then
                continue
            fi

            if [ -z "${host}" ]; then
                continue
            fi

            if [ -z "${menu}" ]; then
                menu="${id}"
            fi

            if [ -z "${title}" ]; then
                title="${id} - ${host}"
            fi

            local nome_base
            local nome_final
            local host_final

            nome_base="$(sanitizar_nome "${id}")"

            if [ -n "${vistos[${nome_base}]:-}" ]; then
                vistos[${nome_base}]="$((vistos[${nome_base}] + 1))"
                nome_final="${nome_base}__${vistos[${nome_base}]}"
            else
                vistos[${nome_base}]=1
                nome_final="${nome_base}"
            fi

            host_final="${host}"

            if [ "${modo_de_alvo}" = "curl_url" ]; then
                host_final="$(transformar_host_para_curl_url "${host}" "${esquema_padrao_para_curl}")"
            fi

            if [ -n "${arquivo_lista}" ]; then
                echo "${nome_final}" >> "${arquivo_lista}"
            fi

            echo "++ ${nome_final}"
            echo "menu = ${menu}"
            echo "title = ${title}"
            echo "host = ${host_final}"

            if [ "${modo_de_alvo}" = "tcpping" ]; then
                if [ -n "${port}" ]; then
                    if printf '%s' "${port}" | grep -Eq '^[0-9]+$'; then
                        echo "port = ${port}"
                    fi
                fi
            fi

            echo ""
        done

        echo "${marcador_fim}"
    } > "${arquivo_bloco}"
}

atualizar_targets_com_bloco() {
    local nome_do_grupo="$1"
    local arquivo_bloco="$2"
    local arquivo_targets="$3"
    local arquivo_targets_temporario="$4"

    local marcador_inicio
    local marcador_fim

    marcador_inicio="# BEGIN AUTO-GENERATED TARGETS GROUP: ${nome_do_grupo}"
    marcador_fim="# END AUTO-GENERATED TARGETS GROUP: ${nome_do_grupo}"

    if [ ! -f "${arquivo_targets}" ]; then
        {
            echo "*** Targets ***"
            echo ""
        } > "${arquivo_targets}"
    fi

    awk -v inicio="${marcador_inicio}" -v fim="${marcador_fim}" '
        $0 == inicio { ignorar = 1; next }
        $0 == fim { ignorar = 0; next }
        ignorar != 1 { print }
    ' "${arquivo_targets}" > "${arquivo_targets_temporario}"

    if [ -s "${arquivo_targets_temporario}" ]; then
        echo "" >> "${arquivo_targets_temporario}"
    fi

    cat "${arquivo_bloco}" >> "${arquivo_targets_temporario}"
    echo "" >> "${arquivo_targets_temporario}"
}

limpar_dados_orfaos() {
    local nome_do_grupo="$1"
    local arquivo_lista="$2"

    if [ -z "${nome_do_grupo}" ] || [ -z "${arquivo_lista}" ]; then
        return 0
    fi

    if [ ! -d "/data/${nome_do_grupo}" ]; then
        return 0
    fi

    if [ ! -s "${arquivo_lista}" ]; then
        return 0
    fi

    local entrada
    for entrada in /data/"${nome_do_grupo}"/*; do
        if [ ! -e "${entrada}" ]; then
            continue
        fi

        local base
        base="$(basename "${entrada}")"
        base="${base%.rrd}"

        if ! grep -Fxq "${base}" "${arquivo_lista}"; then
            rm -rf "${entrada}"
        fi
    done
}

ARQUIVO_JSON_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

ARQUIVO_BLOCO_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

ARQUIVO_LISTA_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_LISTA_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_LISTA_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_LISTA_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

limpeza() {
    rm -f \
        "${ARQUIVO_JSON_GAMES_TEMPORARIO}" \
        "${ARQUIVO_JSON_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_JSON_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_JSON_TCPPING_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_GAMES_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_GAMES_TEMPORARIO}" \
        "${ARQUIVO_LISTA_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_TCPPING_IPV4_TEMPORARIO}" \
        "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}" \
        "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}"
}
trap limpeza EXIT

NECESSITA_RECARREGAR="nao"

if [ -n "${GAMES_JSON_URL:-}" ] && [ -n "${GAMES_GROUP_NAME:-}" ]; then
    baixar_json_para_arquivo "${GAMES_JSON_URL}" "${ARQUIVO_JSON_GAMES_TEMPORARIO}"

    gerar_bloco_targets \
        "${GAMES_GROUP_NAME}" \
        "${GAMES_GROUP_NAME}" \
        "${GAMES_GROUP_NAME}" \
        "FPing" \
        "" \
        "" \
        "normal" \
        "" \
        "${ARQUIVO_JSON_GAMES_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_GAMES_TEMPORARIO}" \
        "${ARQUIVO_LISTA_GAMES_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${GAMES_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_GAMES_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}"

    if [ ! -f "${TARGETS_FILE}" ]; then
        echo "*** Targets ***" > "${TARGETS_FILE}"
        echo "" >> "${TARGETS_FILE}"
    fi

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
        limpar_dados_orfaos "${GAMES_GROUP_NAME}" "${ARQUIVO_LISTA_GAMES_TEMPORARIO}"
        NECESSITA_RECARREGAR="sim"
    fi
fi

if [ -n "${DNS_IPV4_JSON_URL:-}" ] && [ -n "${DNS_IPV4_GROUP_NAME:-}" ]; then
    baixar_json_para_arquivo "${DNS_IPV4_JSON_URL}" "${ARQUIVO_JSON_DNS_IPV4_TEMPORARIO}"

    LINHA_EXTRA_DNS="lookup = ${DNS_IPV4_LOOKUP:-google.com}"

    gerar_bloco_targets \
        "${DNS_IPV4_GROUP_NAME}" \
        "DNS IPv4" \
        "DNS IPv4" \
        "DNS" \
        "${LINHA_EXTRA_DNS}" \
        "" \
        "normal" \
        "" \
        "${ARQUIVO_JSON_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_DNS_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${DNS_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}"

    if [ ! -f "${TARGETS_FILE}" ]; then
        echo "*** Targets ***" > "${TARGETS_FILE}"
        echo "" >> "${TARGETS_FILE}"
    fi

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
        limpar_dados_orfaos "${DNS_IPV4_GROUP_NAME}" "${ARQUIVO_LISTA_DNS_IPV4_TEMPORARIO}"
        NECESSITA_RECARREGAR="sim"
    fi
fi

if [ -n "${HTTP_IPV4_JSON_URL:-}" ] && [ -n "${HTTP_IPV4_GROUP_NAME:-}" ]; then
    baixar_json_para_arquivo "${HTTP_IPV4_JSON_URL}" "${ARQUIVO_JSON_HTTP_IPV4_TEMPORARIO}"

    LINHA_EXTRA_HTTP_1="urlformat = ${HTTP_IPV4_URLFORMAT:-%host%}"

    gerar_bloco_targets \
        "${HTTP_IPV4_GROUP_NAME}" \
        "HTTP IPv4" \
        "HTTP IPv4" \
        "Curl" \
        "${LINHA_EXTRA_HTTP_1}" \
        "" \
        "curl_url" \
        "${HTTP_IPV4_DEFAULT_SCHEME:-http}" \
        "${ARQUIVO_JSON_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_HTTP_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${HTTP_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}"

    if [ ! -f "${TARGETS_FILE}" ]; then
        echo "*** Targets ***" > "${TARGETS_FILE}"
        echo "" >> "${TARGETS_FILE}"
    fi

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
        limpar_dados_orfaos "${HTTP_IPV4_GROUP_NAME}" "${ARQUIVO_LISTA_HTTP_IPV4_TEMPORARIO}"
        NECESSITA_RECARREGAR="sim"
    fi
fi

if [ -n "${TCPPING_IPV4_JSON_URL:-}" ] && [ -n "${TCPPING_IPV4_GROUP_NAME:-}" ]; then
    baixar_json_para_arquivo "${TCPPING_IPV4_JSON_URL}" "${ARQUIVO_JSON_TCPPING_IPV4_TEMPORARIO}"

    LINHA_EXTRA_TCPPING_1="port = ${TCPPING_IPV4_DEFAULT_PORT:-80}"

    gerar_bloco_targets \
        "${TCPPING_IPV4_GROUP_NAME}" \
        "TCPPing IPv4" \
        "TCPPing IPv4" \
        "TCPPing" \
        "${LINHA_EXTRA_TCPPING_1}" \
        "" \
        "tcpping" \
        "" \
        "${ARQUIVO_JSON_TCPPING_IPV4_TEMPORARIO}" \
        "${ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO}" \
        "${ARQUIVO_LISTA_TCPPING_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${TCPPING_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}"

    if [ ! -f "${TARGETS_FILE}" ]; then
        echo "*** Targets ***" > "${TARGETS_FILE}"
        echo "" >> "${TARGETS_FILE}"
    fi

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
        limpar_dados_orfaos "${TCPPING_IPV4_GROUP_NAME}" "${ARQUIVO_LISTA_TCPPING_IPV4_TEMPORARIO}"
        NECESSITA_RECARREGAR="sim"
    fi
fi

if [ "${NECESSITA_RECARREGAR}" = "sim" ]; then
    if docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
        docker exec "${CONTAINER_NAME}" pkill -f -HUP '/usr/bin/perl /usr/s?bin/smokeping(_cgi)?' || true
    fi
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
        sh -c 'apk add --no-cache bash curl jq >/dev/null 2>&1 || true; while true; do /sync/smokeping-sync-games-targets.sh || true; sleep "$((INTERVALO_SINCRONIZACAO_EM_MINUTOS * 60))"; done'
}

parar_container_se_existir "${NOME_DO_CONTAINER_SINCRONIZADOR}"
parar_container_se_existir "${NOME_DO_CONTAINER}"

garantir_configuracao_padrao_completa
resetar_targets_para_grupos_dinamicos
tratar_mudanca_de_pings_e_step_se_necessario
recriar_arquivo_probes_com_parametros_desejados
recriar_general_e_forcar_datadir_em_pathnames_se_existir
criar_redirecionamento_para_raiz

criar_arquivos_do_sincronizador

validar_configuracao_smokeping

iniciar_ou_recriar_container_smokeping
iniciar_container_sincronizador

docker exec "${NOME_DO_CONTAINER_SINCRONIZADOR}" /bin/sh -c 'apk add --no-cache bash curl jq >/dev/null 2>&1 || true; /sync/smokeping-sync-games-targets.sh || true' >/dev/null 2>&1 || true

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
