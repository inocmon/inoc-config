#!/bin/bash

cd /opt/
#
git clone https://github.com/inocmon/inoc-config.git
#
cd inoc-config/
#
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


## instalando certificados
mkdir -p /opt/inoc-config/certs

openssl req -nodes -new -x509 \
  -keyout /opt/inoc-config/certs/server.key \
  -out /opt/inoc-config/certs/server.cert \
  -days 365 \
  -subj "/C=BR/ST=Sao Paulo/L=Sao Paulo/O=Inocmon/OU=TI/CN=localhost/emailAddress=rinaldopvaz@gmail.com"

chmod 600 /opt/inoc-config/certs/server.key
chmod 644 /opt/inoc-config/certs/server.cert
#
#copiar arquivos 
#
(sleep 60; systemctl stop inoc-node-terminal) &
#
sleep 2
#
(sleep 60; cp inoc-node-* /usr/bin/) &
#
sleep 2
#
(sleep 60; chmod +x /usr/bin/inoc-*) &
#
sleep 2
#
(sleep 60; mv inoc-node-terminal.service /etc/systemd/system/inoc-node-terminal.service) &
#
sleep 2
#
(sleep 60; systemctl daemon-reload) &
#
sleep 2
#
(sleep 60; systemctl enable inoc-node-terminal) &
#
sleep 2
#
(sleep 60; systemctl start inoc-node-terminal) &
#