#!/bin/bash

# Este script instala o LibreNMS automaticamente em sistemas Ubuntu/Debian.

# Verifica se é root
if [ "$EUID" -ne 0 ]; then
  echo "Por favor, execute como root"
  exit 1
fi

# Evita interações durante instalação
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Variáveis padrão
SNMP_COMMUNITY="public"
SERVER_IP="127.0.0.1"

# Processa parâmetros
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --snmpcommunity)
      SNMP_COMMUNITY="$2"
      shift
      ;;
    --serverip)
      SERVER_IP="$2"
      shift
      ;;
    --install)
      ACTION="install"
      ;;
    --uninstall)
      ACTION="uninstall"
      ;;
    *)
      echo "Parâmetro inválido: $1"
      echo "Uso: $0 [--install|--uninstall] [--snmpcommunity COMMUNITY] [--serverip IP]"
      exit 1
      ;;
  esac
  shift
done



# Função para instalação
install_librenms() {
apt update
apt-get -yq -o Dpkg::Options::="--force-confdef" \
           -o Dpkg::Options::="--force-confold" upgrade


# Instala dependências básicas
apt install -y software-properties-common curl apt-transport-https ca-certificates gnupg


# Instala PHP 8.2
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y  apache2 php8.2 php8.2-cli php8.2-common php8.2-curl php8.2-fpm php8.2-gd php8.2-gmp php8.2-json php8.2-mbstring php8.2-mysql php8.2-snmp php8.2-xml php8.2-zip libapache2-mod-php8.2

apt remove -y php8.1 php8.1-*

update-alternatives --set php /usr/bin/php8.2
a2dismod php8.1
a2enmod php8.2
systemctl restart apache2




# Cria usuário LibreNMS
useradd librenms -d /opt/librenms -M -r -s /bin/bash

# Clona o LibreNMS
if [ ! -d "/opt/librenms/.git" ]; then
    git clone https://github.com/librenms/librenms.git /opt/librenms
else
    echo "Diretório LibreNMS já existe, atualizando..."
    cd /opt/librenms && git pull
fi

# Define permissões
chown -R librenms:librenms /opt/librenms
chmod 770 /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/
setfacl -R -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/

# Instala dependências PHP
if [ ! -d "/opt/librenms/vendor" ]; then
    su - librenms -c "/usr/bin/composer install --no-dev"
else
    echo "Dependências já existem, atualizando..."
    su - librenms -c "/usr/bin/composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader"
fi

# Verifica se o banco de dados já existe
if ! mysql -u root -e 'use librenms;' 2>/dev/null; then
    echo "Banco de dados não encontrado. Criando..."
    mysql -u root <<EOF
CREATE DATABASE librenms CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'librenms'@'localhost' IDENTIFIED BY 'SenhaSegura123!';
GRANT ALL PRIVILEGES ON librenms.* TO 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF
else
    echo "Banco de dados librenms já existe, ignorando criação."
fi

# Configuração do PHP
sed -i "s/;date.timezone =/date.timezone = America\/Sao_Paulo/" /etc/php/*/apache2/php.ini
sed -i "s/;date.timezone =/date.timezone = America\/Sao_Paulo/" /etc/php/*/cli/php.ini

# Configura Apache
if [ ! -f "/etc/apache2/sites-available/librenms.conf" ]; then
    cat > /etc/apache2/sites-available/librenms.conf <<EOL
<VirtualHost *:80>
  DocumentRoot /opt/librenms/html/
  ServerName librenms.example.com

  AllowEncodedSlashes NoDecode
  <Directory "/opt/librenms/html/">
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/librenms_error.log
  CustomLog \${APACHE_LOG_DIR}/librenms_access.log combined
</VirtualHost>
EOL

    a2ensite librenms.conf
    a2enmod rewrite proxy_fcgi setenvif env headers
    systemctl restart apache2
else
    echo "Configuração Apache já existente. Ignorando."
fi

if [ -f "/opt/librenms/librenms.nonroot.cron" ]; then
    cp /opt/librenms/librenms.nonroot.cron /etc/cron.d/librenms
    chmod 644 /etc/cron.d/librenms
    chown root:root /etc/cron.d/librenms
else
    echo "❌ ERRO: librenms.nonroot.cron ainda não encontrado. Verifique logs do composer."
fi



# Configuração do logrotate
if [ ! -f "/etc/logrotate.d/librenms" ]; then
    cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
fi



# Configuração SNMP
if [ ! -f "/etc/snmp/snmpd.conf.bkp" ]; then
    mv /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.bkp
fi
cp /opt/librenms/snmpd.conf.example /etc/snmp/snmpd.conf
sed -i "s/RANDOMSTRINGGOESHERE/${SNMP_COMMUNITY}/g" /etc/snmp/snmpd.conf

if [ ! -f "/usr/bin/distro" ]; then
    curl -o /usr/bin/distro https://raw.githubusercontent.com/librenms/librenms-agent/master/snmp/distro
    chmod +x /usr/bin/distro
fi
systemctl enable snmpd
systemctl restart snmpd

chown -R librenms:www-data /opt/librenms
chmod -R 775 /opt/librenms


#scheduller
cp /opt/librenms/dist/librenms-scheduler.service /opt/librenms/dist/librenms-scheduler.timer /etc/systemd/system/
systemctl enable librenms-scheduler.timer
systemctl start librenms-scheduler.timer

#
ln -s /opt/librenms/lnms /usr/local/bin/lnms
cp /opt/librenms/misc/lnms-completion.bash /etc/bash_completion.d/

#incluir librenms no grupo e sjusta permissões
usermod -a -G librenms www-data



# Ajusta permissões gerais corretamente
chmod -R ug=rwX /opt/librenms/logs /opt/librenms/rrd /opt/librenms/bootstrap/cache /opt/librenms/storage


# Criar cron do LibreNMS automaticamente com Python Wrapper incluído
cat << 'EOF' > /etc/cron.d/librenms
SHELL=/bin/bash

# LibreNMS cron jobs
33 */6 * * * librenms /opt/librenms/discovery.php -h all >> /dev/null 2>&1
*/5 * * * * librenms /opt/librenms/cronic /opt/librenms/poller-wrapper.py 16
15 0 * * * librenms /opt/librenms/daily.sh >> /dev/null 2>&1
* * * * * librenms /opt/librenms/alerts.php >> /dev/null 2>&1
EOF

# Aplica as permissões corretas automaticamente
chmod 644 /etc/cron.d/librenms
chown root:root /etc/cron.d/librenms

# Reinicia cron automaticamente
systemctl restart cron


# Instala pacotes necessários do Python
apt install -y python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel

# Instala dependências Python do LibreNMS como usuário 'librenms'
su - librenms -c "/usr/bin/pip3 install --user -r /opt/librenms/requirements.txt"




# Adiciona safe directory ao git para resolver "dubious ownership"
su - librenms -c "git config --global --add safe.directory /opt/librenms"

# Limpa e atualiza repositório git
su - librenms -c "git -C /opt/librenms reset --hard"
su - librenms -c "git -C /opt/librenms clean -fd"
su - librenms -c "git -C /opt/librenms checkout master"
su - librenms -c "git -C /opt/librenms pull --quiet"


# Restaura propriedade correta para todo o diretório do LibreNMS
chown -R librenms:librenms /opt/librenms
setfacl -d -m g::rwx /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/
chmod -R ug=rwX /opt/librenms/rrd /opt/librenms/logs /opt/librenms/bootstrap/cache/ /opt/librenms/storage/


# Reinicia Apache
systemctl restart apache2

# Mensagem final
echo "Instalação do LibreNMS concluída. Acesse via navegador o endereço IP ou nome de domínio configurado."
}



# Função para desinstalação
uninstall_librenms() {
    systemctl stop librenms-scheduler.timer
    systemctl disable librenms-scheduler.timer
    rm -f /etc/systemd/system/librenms-scheduler.*
    systemctl daemon-reload

    a2dissite librenms.conf
    rm -f /etc/apache2/sites-available/librenms.conf
    systemctl restart apache2

    rm -f /etc/cron.d/librenms
    rm -f /etc/logrotate.d/librenms

    if [ -f "/etc/snmp/snmpd.conf.bkp" ]; then
        mv /etc/snmp/snmpd.conf.bkp /etc/snmp/snmpd.conf
    fi
    systemctl restart snmpd

    rm -f /usr/local/bin/lnms
    rm -f /etc/bash_completion.d/lnms-completion.bash

    mysql -u root <<EOF
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

    deluser --remove-home librenms
    groupdel librenms

    rm -rf /opt/librenms

    echo "✅ LibreNMS foi completamente desinstalado."
}


# Executa ação
if [ "$ACTION" == "install" ]; then
  install_librenms
elif [ "$ACTION" == "uninstall" ]; then
  uninstall_librenms
else
  echo "Ação não especificada. Use --install ou --uninstall."
  exit 1
fi
