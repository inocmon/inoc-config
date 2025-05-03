#!/bin/bash

# Processando argumentos com getopt
OPTIONS=$(getopt -o '' --long username:,apikey:,refresh-certs-force -- "$@")
eval set -- "$OPTIONS"

userName=""
apiKey=""
REFRESH_CERTS_FORCE=false

while true; do
  case "$1" in
    --username)
      userName="$2"
      shift 2
      ;;
    --apikey)
      apiKey="$2"
      shift 2
      ;;
    --refresh-certs-force)
      REFRESH_CERTS_FORCE=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Erro: Argumento inválido: $1"
      exit 1
      ;;
  esac
done

# Validação de argumentos obrigatórios
if [ -z "$userName" ] || [ -z "$apiKey" ]; then
    echo "Uso: $0 --username Nome_do_usuario --apikey 12345 [--refresh-certs-force]"
    exit 1
fi

# Cria diretórios se não existirem
mkdir -p rsa logs
[ ! -f .env ] && touch .env

# Inserindo dados no arquivo .env
# Atualiza ou adiciona NODE_TERMINAL_API_KEY no .env
if grep -q '^NODE_TERMINAL_API_KEY=' /opt/inoc-config/.env; then
    sed -i "s/^NODE_TERMINAL_API_KEY=.*/NODE_TERMINAL_API_KEY=${apiKey}/" /opt/inoc-config/.env
else
    echo "NODE_TERMINAL_API_KEY=${apiKey}" >> /opt/inoc-config/.env
fi


# Atualizando o usuário no arquivo de serviço
sed -i "s/^User=.*/User=${userName}/" /opt/inoc-config/inoc-node-terminal.service

# Gerar chave RSA se necessário
if [ ! -f rsa/keypair.pem ]; then
    echo "Gerando nova chave RSA..."
    ssh-keygen -t rsa -b 2048 -m PEM -f rsa/keypair.pem -q -N ""
else
    echo "A chave RSA já existe."
fi

echo "# Conteúdo da chave pública:"
cat rsa/keypair.pem.pub

# Instalando certificados SSL
mkdir -p /opt/inoc-config/certs

if [ "$REFRESH_CERTS_FORCE" = true ] || [ ! -f /opt/inoc-config/certs/server.key ] || [ ! -f /opt/inoc-config/certs/server.cert ]; then
    echo "Gerando novo certificado SSL..."

    openssl req -nodes -new -x509 \
      -keyout /opt/inoc-config/certs/server.key \
      -out /opt/inoc-config/certs/server.cert \
      -days 365 \
      -subj "/C=BR/ST=Sao Paulo/L=Sao Paulo/O=Inocmon/OU=TI/CN=localhost/emailAddress=rinaldopvaz@gmail.com"

    chmod 600 /opt/inoc-config/certs/server.key
    chmod 644 /opt/inoc-config/certs/server.cert
else
    echo "O certificado SSL já existe. Utilize '--refresh-certs-force' para gerar um novo."
fi

# Copiar arquivos e configuração do serviço
chmod +x /opt/inoc-config/inoc-node-terminal
chown -R "${userName}:${userName}" /opt/inoc-config

#inoc node terminal
cp inoc-node-terminal inoc-node-terminal-tmp
mv inoc-node-terminal-tmp /usr/bin/inoc-node-terminal
cp inoc-node-terminal.service inoc-node-terminal.service-tmp
mv inoc-node-terminal.service-tmp /etc/systemd/system/inoc-node-terminal.service

#inoc config4
cp inoc-config4 inoc-config4-tmp
mv inoc-config4-tmp /usr/bin/inoc-config4

systemctl daemon-reload
systemctl enable inoc-node-terminal
systemctl restart inoc-node-terminal
