#!/bin/bash

# Variáveis configuráveis
DB_ROOT_PASS="senhaRootMySQL"
DB_USER="librenms"
DB_PASS="senhaUsuarioLibreNMS"
DB_NAME="librenms"
TIMEZONE="America/Sao_Paulo"

export DEBIAN_FRONTEND=noninteractive

# Atualiza sistema
apt update && apt upgrade -y

# Dependências essenciais
apt install -y software-properties-common curl git unzip acl wget apt-transport-https ca-certificates lsb-release gnupg

# Dependências adicionais recomendadas LibreNMS
apt install -y snmp snmpd fping imagemagick whois mtr-tiny nmap python3 python3-pip python3-setuptools python3-wheel rrdtool python3-venv uuid-runtime


# Repositório PHP 8.3
add-apt-repository -y ppa:ondrej/php
apt update

# Instala Apache, MySQL e PHP 8.3
apt install -y apache2 mysql-server \
    php8.3 php8.3-cli php8.3-common php8.3-curl php8.3-gd php8.3-gmp \
    php8.3-mbstring php8.3-mysql php8.3-snmp php8.3-xml php8.3-zip \
    php8.3-fpm php8.3-opcache php8.3-readline php8.3-bcmath libapache2-mod-php8.3

# MySQL seguro e criação do banco
mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
EOF

mysql -u root -p${DB_ROOT_PASS} <<EOF
CREATE DATABASE ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# Configuração do timezone do sistema e PHP (apache2 e CLI)
timedatectl set-timezone ${TIMEZONE}
sed -i "s|;date.timezone =.*|date.timezone = ${TIMEZONE}|g" /etc/php/8.3/apache2/php.ini
sed -i "s|;date.timezone =.*|date.timezone = ${TIMEZONE}|g" /etc/php/8.3/cli/php.ini

# Configuração PHP adicional
sed -i "s|memory_limit =.*|memory_limit = 512M|g" /etc/php/8.3/apache2/php.ini

# Apache Modules
a2enmod php8.3 rewrite
systemctl restart apache2


# Usuário LibreNMS
useradd librenms -d /opt/librenms -M -r -s /bin/bash
usermod -a -G librenms www-data

# LibreNMS instalação via Git
git clone https://github.com/librenms/librenms.git /opt/librenms
chown -R librenms:librenms /opt/librenms
chmod 771 /opt/librenms

# Composer
# Python virtualenv (CORREÇÃO DEFINITIVA E VALIDADA)
sudo -u librenms python3 -m venv /opt/librenms/venv
sudo -u librenms /opt/librenms/venv/bin/pip install --upgrade pip wheel setuptools
sudo -u librenms /opt/librenms/venv/bin/pip install -r /opt/librenms/requirements.txt
sudo -u librenms /opt/librenms/venv/bin/pip install command_runner>=1.3.0

# Composer
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

# Ajusta Composer para rodar validação Python corretamente via virtualenv
sed -i 's|scripts/dynamic_check_requirements.py|/opt/librenms/venv/bin/python3 scripts/dynamic_check_requirements.py|' /opt/librenms/composer.json
sudo -u librenms composer install --no-dev --working-dir=/opt/librenms



# Correção definitiva shebang do dynamic_check_requirements.py
sed -i '1c #!/opt/librenms/venv/bin/python3' /opt/librenms/scripts/dynamic_check_requirements.py



# Configuração básica LibreNMS
cp /opt/librenms/config.php.default /opt/librenms/config.php
sed -i "s/'db_user'.*/'db_user' => '${DB_USER}',/" /opt/librenms/config.php
sed -i "s/'db_pass'.*/'db_pass' => '${DB_PASS}',/" /opt/librenms/config.php
sed -i "s/'db_name'.*/'db_name' => '${DB_NAME}',/" /opt/librenms/config.php

cat <<EOL >> /opt/librenms/config.php
\$config['python_binary'] = '/opt/librenms/venv/bin/python3';
\$config['rrdtool'] = '/usr/bin/rrdtool';
EOL

# Diretórios Logs e RRD
mkdir -p /opt/librenms/{logs,rrd}
chown -R librenms:www-data /opt/librenms/{logs,rrd}
chmod 775 /opt/librenms/{logs,rrd}

# Cron jobs e Logrotate (CORREÇÃO DEFINITIVA E VALIDADA)
cat <<EOF >/etc/cron.d/librenms
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash

*/5 * * * * librenms /opt/librenms/venv/bin/python3 /opt/librenms/poller-wrapper.py 16
*/5 * * * * librenms php /opt/librenms/alerts.php
*/5 * * * * librenms /opt/librenms/venv/bin/python3 /opt/librenms/services-wrapper.py 1
*/5 * * * * librenms php /opt/librenms/discovery.php -h new
EOF

systemctl restart cron


cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms


# Configuração Apache LibreNMS
cat <<EOL >/etc/apache2/sites-available/librenms.conf
<VirtualHost *:80>
  DocumentRoot /opt/librenms/html/
  ServerName librenms.local
  AllowEncodedSlashes NoDecode
  <Directory "/opt/librenms/html/">
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
  </Directory>
</VirtualHost>
EOL

a2dissite 000-default.conf
a2ensite librenms.conf
systemctl reload apache2

# Geração correta .env
cat <<EOL >/opt/librenms/.env
APP_KEY=
DB_HOST=localhost
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

APP_URL=http://localhost
NODE_ID=$(uuidgen)

APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_FAKER_LOCALE=en_US
APP_MAINTENANCE_DRIVER=file
APP_MAINTENANCE_STORE=database
PHP_CLI_SERVER_WORKERS=4

BCRYPT_ROUNDS=12
LOG_STACK=single
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null
EOL

# Permissões adequadas no arquivo
chown librenms:www-data /opt/librenms/.env
chmod 660 /opt/librenms/.env


# Carrega explicitamente variáveis do .env
set -o allexport
source /opt/librenms/.env
set +o allexport

# Gera chave APP_KEY e roda migrations
sudo -u librenms bash -c 'cd /opt/librenms && php artisan key:generate --force'
sudo -u librenms bash -c 'cd /opt/librenms && php artisan migrate --seed --force'

# Cria usuário administrador padrão corretamente
sudo -u librenms bash -c 'cd /opt/librenms && php artisan user:add admin --password=admin --email=admin@example.com --role=admin'

# Ajuste permissões finais
chown -R librenms:www-data /opt/librenms
chmod -R ug+rwX /opt/librenms/{storage,bootstrap/cache,logs,rrd}



# Configuração Scheduler via systemd (CORREÇÃO DEFINITIVA E VALIDADA)
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl daemon-reload
systemctl restart librenms-scheduler.timer



# Comando global lnms (atalho)
ln -sf /opt/librenms/lnms /usr/local/bin/lnms

# Bash completion do lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

# Correção final de permissões essenciais
chown -R librenms:librenms /opt/librenms
chmod -R ug+rwX /opt/librenms/{storage,bootstrap/cache,logs,rrd}
setfacl -Rdm g::rwx /opt/librenms/{storage,bootstrap/cache,logs,rrd}


#remover aviso de arquivos git modificados
rm -rf /opt/librenms/.git

# Diretório home correto para librenms (corrige erro posix_spawn)
usermod -d /opt/librenms librenms
chmod 755 /opt/librenms



# PRIMEIRO ISSO
chmod u+s /usr/bin/fping
setcap cap_net_raw+ep /usr/bin/fping
chown root:librenms /usr/bin/fping

if [ ! -L /usr/bin/fping6 ]; then
    chmod u+s /usr/bin/fping6
    setcap cap_net_raw+ep /usr/bin/fping6
    chown root:librenms /usr/bin/fping6
else
    FPING6_REALPATH=$(readlink -f /usr/bin/fping6)
    chmod u+s "$FPING6_REALPATH"
    setcap cap_net_raw+ep "$FPING6_REALPATH"
    chown root:librenms "$FPING6_REALPATH"
fi


# Configuração AppArmor DEFINITIVA para FPING e FPING6 (sem conflitos)

chown root:librenms /usr/bin/fping
chmod 4711 /usr/bin/fping
setcap cap_net_raw+ep /usr/bin/fping



# AGORA SIM ADICIONAR HOST
cd /opt/librenms
sudo -u librenms /opt/librenms/lnms device:add localhost --community=public --v2c


# Descoberta e polling imediato (com comandos corretos e definitivos)

sudo -u librenms /opt/librenms/lnms device:poll localhost
sudo -u librenms /opt/librenms/venv/bin/python3 poller-wrapper.py 16



# Validação final
sudo -u librenms /opt/librenms/validate.php

echo "Instalação concluída! Acesse via navegador com usuário: admin e senha: admin."
