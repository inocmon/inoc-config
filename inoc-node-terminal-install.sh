#!/bin/bash

cd /opt/

git clone https://github.com/inocmon/inoc-config.git

cd inoc-config/

git pull

# Cria o diretório "rsa" apenas se ele não existir
[ ! -d rsa ] && mkdir rsa

# Gera a chave RSA apenas se ela não existir
if [ ! -f rsa/keypair.pem ]; then
    echo "Gerando nova chave RSA..."
    ssh-keygen -t rsa -b 2048 -m PEM -f rsa/keypair.pem -q -N ""
else
    echo "A chave RSA já existe."
fi

echo "# Conteúdo da chave pública:"
echo "#"
cat rsa/keypair.pem.pub

# Instalando certificados
mkdir -p /opt/inoc-config/certs

REFRESH_CERTS_FORCE=false
if [[ "$1" == "--refresh-certs-force" ]]; then
    REFRESH_CERTS_FORCE=true
fi

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
cp inoc-node-terminal inoc-node-terminal.tmp
cp inoc-node-terminal.tmp /usr/bin/inoc-node-terminal.tmp

cp inoc-node-terminal.service inoc-node-terminal.service.tmp
mv inoc-node-terminal.service.tmp /etc/systemd/system/inoc-node-terminal.service

systemctl daemon-reload
systemctl enable inoc-node-terminal
systemctl restart inoc-node-terminal
