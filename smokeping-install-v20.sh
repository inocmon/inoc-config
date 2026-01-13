#!/usr/bin/env bash
set -euo pipefail

NOME_DO_CONTAINER="${NOME_DO_CONTAINER:-smokeping}"
IMAGEM_DO_CONTAINER="${IMAGEM_DO_CONTAINER:-lscr.io/linuxserver/smokeping:latest}"
PORTA_HTTP_NO_HOST="${PORTA_HTTP_NO_HOST:-8080}"

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

if [ "$(id -u)" -ne 0 ]; then
    echo "Execute como root."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker nao encontrado."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl nao encontrado."
    exit 1
fi

instalar_jq_se_necessario() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y jq
        return 0
    fi

    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache jq
        return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        dnf install -y jq
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        yum install -y jq
        return 0
    fi

    echo "Nao foi possivel instalar jq automaticamente. Instale jq e execute novamente."
    exit 1
}

instalar_rrdtool_se_necessario() {
    if command -v rrdtool >/dev/null 2>&1; then
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y rrdtool
        return 0
    fi

    echo "Nao foi possivel instalar rrdtool automaticamente. Instale rrdtool e execute novamente."
    exit 1
}

instalar_jq_se_necessario
instalar_rrdtool_se_necessario


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

CONTAINER_EXISTE="nao"
if docker ps -a --format '{{.Names}}' | grep -Fxq "${NOME_DO_CONTAINER}"; then
    CONTAINER_EXISTE="sim"
fi

DIRETORIO_CONFIGURACAO=""
DIRETORIO_DADOS=""

if [ "${CONTAINER_EXISTE}" = "sim" ]; then
    DIRETORIO_CONFIGURACAO="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/config" }}{{ .Source }}{{ end }}{{ end }}' "${NOME_DO_CONTAINER}")"
    DIRETORIO_DADOS="$(docker inspect --format '{{ range .Mounts }}{{ if eq .Destination "/data" }}{{ .Source }}{{ end }}{{ end }}' "${NOME_DO_CONTAINER}")"

    if [ -z "${DIRETORIO_CONFIGURACAO}" ]; then
        echo "Nao foi encontrado mount para /config no container ${NOME_DO_CONTAINER}."
        exit 1
    fi

    if [ -z "${DIRETORIO_DADOS}" ]; then
        echo "Nao foi encontrado mount para /data no container ${NOME_DO_CONTAINER}."
        exit 1
    fi

    mkdir -p "${DIRETORIO_CONFIGURACAO}"
    mkdir -p "${DIRETORIO_DADOS}"
    chown -R "${PUID}:${PGID}" "${DIRETORIO_CONFIGURACAO}" "${DIRETORIO_DADOS}" 2>/dev/null || true
else
    DIRETORIO_CONFIGURACAO="${DIRETORIO_BASE_PADRAO}/config"
    DIRETORIO_DADOS="${DIRETORIO_BASE_PADRAO}/data"

    mkdir -p "${DIRETORIO_CONFIGURACAO}"
    mkdir -p "${DIRETORIO_DADOS}"

    chown -R "${PUID}:${PGID}" "${DIRETORIO_CONFIGURACAO}" "${DIRETORIO_DADOS}" 2>/dev/null || true

    docker pull "${IMAGEM_DO_CONTAINER}"

    docker run -d \
        --name="${NOME_DO_CONTAINER}" \
        -e PUID="${PUID}" \
        -e PGID="${PGID}" \
        -e TZ="${FUSO_HORARIO}" \
        -p "${PORTA_HTTP_NO_HOST}:80" \
        -v "${DIRETORIO_CONFIGURACAO}:/config" \
        -v "${DIRETORIO_DADOS}:/data" \
        --restart unless-stopped \
        "${IMAGEM_DO_CONTAINER}"
fi

ARQUIVO_TARGETS="${DIRETORIO_CONFIGURACAO}/Targets"
ARQUIVO_PROBES="${DIRETORIO_CONFIGURACAO}/Probes"
DIRETORIO_SITE_CONFS="${DIRETORIO_CONFIGURACAO}/site-confs"
ARQUIVO_HTTPD_CONF="${DIRETORIO_CONFIGURACAO}/httpd.conf"
ARQUIVO_REDIRECIONAMENTO_RAIZ="${DIRETORIO_SITE_CONFS}/00-root-smokeping.conf"

criar_backup_do_arquivo() {
    local arquivo="$1"
    if [ -f "${arquivo}" ]; then
        local data_hora
        data_hora="$(date +%Y%m%d-%H%M%S)"
        cp -f "${arquivo}" "${arquivo}.bak.${data_hora}"
    fi
}

configuracao_esta_vazia() {
    if [ ! -d "${DIRETORIO_CONFIGURACAO}" ]; then
        return 0
    fi

    if [ -z "$(ls -A "${DIRETORIO_CONFIGURACAO}" 2>/dev/null || true)" ]; then
        return 0
    fi

    return 1
}

extrair_configuracao_padrao_completa_da_imagem() {
    docker pull "${IMAGEM_DO_CONTAINER}"

    local caminho_targets_padrao
    caminho_targets_padrao="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'for p in /defaults/smoke-conf/Targets /root/defaults/smoke-conf/Targets /usr/share/smokeping/config.d/Targets /etc/smokeping/config.d/Targets; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"

    local diretorio_config_padrao
    diretorio_config_padrao="$(dirname "${caminho_targets_padrao}")"

    local id_container_temporario
    id_container_temporario="$(docker create "${IMAGEM_DO_CONTAINER}")"

    mkdir -p "${DIRETORIO_CONFIGURACAO}"

    docker cp "${id_container_temporario}:${diretorio_config_padrao}/." "${DIRETORIO_CONFIGURACAO}"

    docker rm -f "${id_container_temporario}" >/dev/null 2>&1 || true

    chown -R "${PUID}:${PGID}" "${DIRETORIO_CONFIGURACAO}" 2>/dev/null || true
}

if configuracao_esta_vazia; then
    if docker ps --format '{{.Names}}' | grep -Fxq "${NOME_DO_CONTAINER}"; then
        docker stop "${NOME_DO_CONTAINER}" >/dev/null 2>&1 || true
    fi

    extrair_configuracao_padrao_completa_da_imagem
fi

targets_possui_host() {
    if [ ! -f "${ARQUIVO_TARGETS}" ]; then
        return 1
    fi
    if grep -Eq '^[[:space:]]*host[[:space:]]*=' "${ARQUIVO_TARGETS}"; then
        return 0
    fi
    return 1
}

restaurar_targets_de_backup_valido() {
    local arquivo_encontrado=""

    if ls -1 "${DIRETORIO_CONFIGURACAO}"/Targets.bak.* >/dev/null 2>&1; then
        arquivo_encontrado="$(ls -1 "${DIRETORIO_CONFIGURACAO}"/Targets.bak.* 2>/dev/null | sort -r | head -n 1)"
    fi

    if [ -n "${arquivo_encontrado}" ]; then
        if grep -Eq '^[[:space:]]*host[[:space:]]*=' "${arquivo_encontrado}"; then
            criar_backup_do_arquivo "${ARQUIVO_TARGETS}"
            cp -f "${arquivo_encontrado}" "${ARQUIVO_TARGETS}"
            return 0
        fi
    fi

    return 1
}

extrair_targets_padrao_da_imagem() {
    docker pull "${IMAGEM_DO_CONTAINER}"

    local caminho_targets_padrao
    caminho_targets_padrao="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'for p in /defaults/smoke-conf/Targets /root/defaults/smoke-conf/Targets /usr/share/smokeping/config.d/Targets /etc/smokeping/config.d/Targets; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"

    criar_backup_do_arquivo "${ARQUIVO_TARGETS}"

    docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c "cat \"${caminho_targets_padrao}\"" > "${ARQUIVO_TARGETS}"
}

extrair_probes_padrao_da_imagem_se_nao_existir() {
    if [ -f "${ARQUIVO_PROBES}" ]; then
        return 0
    fi

    docker pull "${IMAGEM_DO_CONTAINER}"

    local caminho_probes_padrao
    caminho_probes_padrao="$(docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c 'for p in /defaults/smoke-conf/Probes /root/defaults/smoke-conf/Probes /usr/share/smokeping/config.d/Probes /etc/smokeping/config.d/Probes; do if [ -f "$p" ]; then echo "$p"; exit 0; fi; done; exit 1')"

    docker run --rm --entrypoint /bin/sh "${IMAGEM_DO_CONTAINER}" -c "cat \"${caminho_probes_padrao}\"" > "${ARQUIVO_PROBES}"
}

atualizar_bloco_curl_no_probes() {
    extrair_probes_padrao_da_imagem_se_nao_existir

    criar_backup_do_arquivo "${ARQUIVO_PROBES}"

    local arquivo_temporario
    arquivo_temporario="$(mktemp)"

    if grep -Eq '^\+[[:space:]]+Curl[[:space:]]*$' "${ARQUIVO_PROBES}"; then
        awk '
            BEGIN {
                pulando = 0
            }
            /^\+[[:space:]]+Curl[[:space:]]*$/ {
                print "+ Curl"
                print "binary = /usr/bin/curl"
                print "forks = 2"
                print "offset = 50%"
                print "step = 300"
                print "pings = 3"
                print "extraargs = -o /dev/null -sS "
                print ""
                pulando = 1
                next
            }
            pulando == 1 && /^\+[[:space:]]+/ {
                pulando = 0
            }
            pulando == 0 {
                print
            }
        ' "${ARQUIVO_PROBES}" > "${arquivo_temporario}"
    else
        cat "${ARQUIVO_PROBES}" > "${arquivo_temporario}"
        echo "" >> "${arquivo_temporario}"
        echo "+ Curl" >> "${arquivo_temporario}"
        echo "binary = /usr/bin/curl" >> "${arquivo_temporario}"
        echo "forks = 2" >> "${arquivo_temporario}"
        echo "offset = 50%" >> "${arquivo_temporario}"
        echo "step = 300" >> "${arquivo_temporario}"
        echo "pings = 3" >> "${arquivo_temporario}"
        echo "extraargs = -o /dev/null -sS " >> "${arquivo_temporario}"
        echo "" >> "${arquivo_temporario}"
    fi

    mv -f "${arquivo_temporario}" "${ARQUIVO_PROBES}"
    chmod 0644 "${ARQUIVO_PROBES}"
}

atualizar_blocos_fping_no_probes() {
    extrair_probes_padrao_da_imagem_se_nao_existir

    criar_backup_do_arquivo "${ARQUIVO_PROBES}"

    local arquivo_temporario
    arquivo_temporario="$(mktemp)"

    local encontrou_fping="nao"
    local encontrou_fping6="nao"

    if grep -Eq '^\+[[:space:]]+FPing[[:space:]]*$' "${ARQUIVO_PROBES}"; then
        encontrou_fping="sim"
    fi

    if grep -Eq '^\+[[:space:]]+FPing6[[:space:]]*$' "${ARQUIVO_PROBES}"; then
        encontrou_fping6="sim"
    fi

    awk '
        BEGIN {
            pulando = 0
        }

        /^\+[[:space:]]+FPing[[:space:]]*$/ {
            print "+ FPing"
            print "binary = /usr/sbin/fping"
            print "pings = 100"
            print "step = 300"
            print ""
            pulando = 1
            next
        }

        /^\+[[:space:]]+FPing6[[:space:]]*$/ {
            print "+ FPing6"
            print "binary = /usr/sbin/fping"
            print "protocol = 6"
            print "pings = 100"
            print "step = 300"
            print ""
            pulando = 1
            next
        }

        pulando == 1 && /^\+[[:space:]]+/ {
            pulando = 0
        }

        pulando == 0 {
            print
        }
    ' "${ARQUIVO_PROBES}" > "${arquivo_temporario}"

    if [ "${encontrou_fping}" = "nao" ]; then
        echo "" >> "${arquivo_temporario}"
        echo "+ FPing" >> "${arquivo_temporario}"
        echo "binary = /usr/sbin/fping" >> "${arquivo_temporario}"
        echo "pings = 100" >> "${arquivo_temporario}"
        echo "step = 300" >> "${arquivo_temporario}"
        echo "" >> "${arquivo_temporario}"
    fi

    if [ "${encontrou_fping6}" = "nao" ]; then
        echo "" >> "${arquivo_temporario}"
        echo "+ FPing6" >> "${arquivo_temporario}"
        echo "binary = /usr/sbin/fping" >> "${arquivo_temporario}"
        echo "protocol = 6" >> "${arquivo_temporario}"
        echo "pings = 100" >> "${arquivo_temporario}"
        echo "step = 300" >> "${arquivo_temporario}"
        echo "" >> "${arquivo_temporario}"
    fi

    mv -f "${arquivo_temporario}" "${ARQUIVO_PROBES}"
    chmod 0644 "${ARQUIVO_PROBES}"
}


criar_redirecionamento_para_raiz() {
    mkdir -p "${DIRETORIO_SITE_CONFS}"

    criar_backup_do_arquivo "${ARQUIVO_REDIRECIONAMENTO_RAIZ}"

    cat > "${ARQUIVO_REDIRECIONAMENTO_RAIZ}" << 'EOF'
RedirectMatch 302 ^/$ /smokeping/smokeping.cgi
EOF

    chmod 0644 "${ARQUIVO_REDIRECIONAMENTO_RAIZ}"

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

if ! targets_possui_host; then
    if ! restaurar_targets_de_backup_valido; then
        extrair_targets_padrao_da_imagem
    fi
fi

atualizar_blocos_fping_no_probes
atualizar_bloco_curl_no_probes
criar_redirecionamento_para_raiz

ARQUIVO_CONFIGURACAO_SINCRONIZACAO="/etc/smokeping-games-sync.conf"
cat > "${ARQUIVO_CONFIGURACAO_SINCRONIZACAO}" << EOF
CONTAINER_NAME="${NOME_DO_CONTAINER}"
TARGETS_FILE="${ARQUIVO_TARGETS}"

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

chmod 0644 "${ARQUIVO_CONFIGURACAO_SINCRONIZACAO}"

ARQUIVO_SINCRONIZADOR="/usr/local/bin/smokeping-sync-games-targets.sh"
cat > "${ARQUIVO_SINCRONIZADOR}" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

ARQUIVO_CONFIGURACAO_SINCRONIZACAO="/etc/smokeping-games-sync.conf"
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

ARQUIVO_JSON_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_JSON_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

ARQUIVO_BLOCO_GAMES_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO="$(mktemp)"
ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO="$(mktemp)"

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
        "${ARQUIVO_BLOCO_GAMES_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${GAMES_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_GAMES_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}"

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_GAMES_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
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
        "${ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${DNS_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_DNS_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}"

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_DNS_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
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
        "${ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${HTTP_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_HTTP_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}"

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_HTTP_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
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
        "${ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO}"

    atualizar_targets_com_bloco \
        "${TCPPING_IPV4_GROUP_NAME}" \
        "${ARQUIVO_BLOCO_TCPPING_IPV4_TEMPORARIO}" \
        "${TARGETS_FILE}" \
        "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}"

    if ! cmp -s "${TARGETS_FILE}" "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}"; then
        DATA_HORA="$(date +%Y%m%d-%H%M%S)"
        cp -f "${TARGETS_FILE}" "${TARGETS_FILE}.bak.${DATA_HORA}"
        mv -f "${ARQUIVO_TARGETS_APOS_TCPPING_IPV4_TEMPORARIO}" "${TARGETS_FILE}"
        chmod 0644 "${TARGETS_FILE}"
        NECESSITA_RECARREGAR="sim"
    fi
fi

if [ "${NECESSITA_RECARREGAR}" = "sim" ]; then
    if docker ps --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
        docker exec "${CONTAINER_NAME}" pkill -f -HUP '/usr/bin/perl /usr/s?bin/smokeping(_cgi)?' || true
    fi
fi
EOF

chmod 0755 "${ARQUIVO_SINCRONIZADOR}"

USAR_SYSTEMD="nao"
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    USAR_SYSTEMD="sim"
fi

if [ "${USAR_SYSTEMD}" = "sim" ]; then
    ARQUIVO_SERVICE="/etc/systemd/system/smokeping-games-sync.service"
    cat > "${ARQUIVO_SERVICE}" << EOF
[Unit]
Description=Sincronizar grupos dinamicos no Targets do SmokePing

[Service]
Type=oneshot
ExecStart=${ARQUIVO_SINCRONIZADOR}
EOF

    ARQUIVO_TIMER="/etc/systemd/system/smokeping-games-sync.timer"
    cat > "${ARQUIVO_TIMER}" << EOF
[Unit]
Description=Agendamento da sincronizacao dos grupos dinamicos no SmokePing

[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVALO_SINCRONIZACAO_EM_MINUTOS}min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now smokeping-games-sync.timer
else
    ARQUIVO_CRON="/etc/cron.d/smokeping-games-sync"
    cat > "${ARQUIVO_CRON}" << EOF
*/${INTERVALO_SINCRONIZACAO_EM_MINUTOS} * * * * root ${ARQUIVO_SINCRONIZADOR} >/var/log/smokeping-games-sync.log 2>&1
EOF
    chmod 0644 "${ARQUIVO_CRON}"
fi

"${ARQUIVO_SINCRONIZADOR}"

docker restart "${NOME_DO_CONTAINER}"

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
