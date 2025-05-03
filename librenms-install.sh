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

# Instala pacotes necessários do Python
apt install -y python3 python3-pip python3-venv python3-dev python3-setuptools python3-wheel
apt install -y cronic

# Instala PHP
add-apt-repository -y ppa:ondrej/php
apt update
apt install -y apache2
apt install -y  snmp snmpd rrdtool fping git
apt install -y software-properties-common
apt install composer -y
apt install mysql-server mysql-client -y
apt install -y acl
#mysql_secure_installation
add-apt-repository -y ppa:ondrej/php
apt install -y php php-cli php-common php-curl php-fpm php-gd php-gmp php-mbstring php-mysql php-snmp php-xml php-zip libapache2-mod-php

apt purge -y php*-fpm
apt install -y libapache2-mod-php

PHP_MODULE=$(basename $(find /usr/lib/apache2/modules/ -name "libphp*.so" | sort -r | head -n1) .so | sed 's/lib//')

if [ -z "$PHP_MODULE" ]; then
    echo "❌ Nenhum módulo PHP encontrado no Apache. Verifique instalação."
    exit 1
fi

a2dismod mpm_event mpm_worker php* 2>/dev/null || true
a2enmod mpm_prefork "${PHP_MODULE}"
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

# Garante que composer está disponível para usuário librenms
ln -sf /usr/bin/composer /opt/librenms/composer
chown librenms:librenms /opt/librenms/composer

# Instala dependências PHP com usuário librenms
# Garante as permissões corretas antes do Composer
chown -R librenms:librenms /opt/librenms

# Certifica-se de que composer esteja instalado corretamente
apt install -y composer unzip

# Executa composer com saída para log e verificação automática
COMPOSER_LOG="/tmp/librenms_composer.log"

su - librenms -c "/usr/bin/composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader &> ${COMPOSER_LOG}"

# Verifica automaticamente se librenms.nonroot.cron foi criado
if [ -f "/opt/librenms/misc/librenms.nonroot.cron" ]; then
    cp /opt/librenms/misc/librenms.nonroot.cron /etc/cron.d/librenms
    chmod 644 /etc/cron.d/librenms
    chown root:root /etc/cron.d/librenms
else
    echo "❌ ERRO: librenms.nonroot.cron ainda não encontrado. Log do composer:"
    cat ${COMPOSER_LOG}
    exit 1
fi

# Validação adicional imediata:
[ -f /etc/cron.d/librenms ] || { echo "❌ Cron do LibreNMS não foi criado corretamente!"; exit 1; }

# Configuração do logrotate com validação imediata
if [ -f "/opt/librenms/misc/librenms.logrotate" ]; then
    cp /opt/librenms/misc/librenms.logrotate /etc/logrotate.d/librenms
else
    echo "❌ ERRO: Arquivo logrotate do LibreNMS não encontrado!"
    exit 1
fi

# Validação adicional imediata:
[ -f /etc/logrotate.d/librenms ] || { echo "❌ Logrotate não foi criado corretamente!"; exit 1; }


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
# Garante que o diretório exista
mkdir -p /etc/apache2/sites-available

# Cria ou sobrescreve explicitamente a configuração correta do site LibreNMS
cat <<'EOL' > /etc/apache2/sites-available/librenms.conf
<VirtualHost *:80>
  DocumentRoot /opt/librenms/html/
  ServerName librenms.example.com

  AllowEncodedSlashes NoDecode
  <Directory "/opt/librenms/html/">
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
  </Directory>

  ErrorLog ${APACHE_LOG_DIR}/librenms_error.log
  CustomLog ${APACHE_LOG_DIR}/librenms_access.log combined
</VirtualHost>
EOL

# Desativa site padrão e ativa explicitamente o site LibreNMS
a2dissite 000-default.conf
a2ensite librenms.conf

# Ativa módulos essenciais para o LibreNMS
a2enmod rewrite headers env proxy_fcgi setenvif

# Reinicia Apache para aplicar imediatamente
systemctl restart apache2

# Validação imediata para garantir que LibreNMS esteja realmente acessível
sleep 2
if curl -s http://127.0.0.1 | grep -q "LibreNMS"; then
    echo "✅ LibreNMS configurado e acessível com sucesso!"
else
    echo "❌ Erro: LibreNMS ainda inacessível após configuração!"
    apache2ctl -S
    ls -l /etc/apache2/sites-available/
    exit 1
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
[ -L /usr/local/bin/lnms ] && rm /usr/local/bin/lnms
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
# Função otimizada para desinstalação completa do LibreNMS
uninstall_librenms() {
    echo "⚙️ Iniciando desinstalação completa do LibreNMS..."

    # Para serviços do LibreNMS
    systemctl stop librenms-scheduler.timer librenms-scheduler.service >/dev/null 2>&1
    systemctl disable librenms-scheduler.timer librenms-scheduler.service >/dev/null 2>&1
    rm -f /etc/systemd/system/librenms-scheduler.*

    # Recarrega serviços
    systemctl daemon-reload

    # Remove configurações Apache do LibreNMS
    if [ -f "/etc/apache2/sites-available/librenms.conf" ]; then
        a2dissite librenms.conf >/dev/null 2>&1
        rm -f /etc/apache2/sites-available/librenms.conf
        systemctl restart apache2
    fi

    # Remove cron e logrotate
    rm -f /etc/cron.d/librenms
    rm -f /etc/logrotate.d/librenms

    # Restaura configuração original do SNMP, se backup existir
    if [ -f "/etc/snmp/snmpd.conf.bkp" ]; then
        mv /etc/snmp/snmpd.conf.bkp /etc/snmp/snmpd.conf
        systemctl restart snmpd
    fi

    # Remove scripts e links simbólicos relacionados ao LibreNMS
    rm -f /usr/local/bin/lnms
    rm -f /etc/bash_completion.d/lnms-completion.bash

    # Remove totalmente banco de dados e usuário do LibreNMS do MySQL/MariaDB
    mysql -u root <<EOF
DROP DATABASE IF EXISTS librenms;
DROP USER IF EXISTS 'librenms'@'localhost';
FLUSH PRIVILEGES;
EOF

    # Remove usuário e grupo librenms
    if id "librenms" >/dev/null 2>&1; then
        deluser --remove-home librenms >/dev/null 2>&1
    fi

    if getent group librenms >/dev/null 2>&1; then
        groupdel librenms >/dev/null 2>&1
    fi

    # Remove completamente diretório de instalação do LibreNMS
    rm -rf /opt/librenms

    # Limpa resíduos adicionais possivelmente deixados
    find /var/log -name "*librenms*" -exec rm -rf {} \; >/dev/null 2>&1
    find /tmp -name "*librenms*" -exec rm -rf {} \; >/dev/null 2>&1

    echo "✅ LibreNMS foi completamente removido do sistema."
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
