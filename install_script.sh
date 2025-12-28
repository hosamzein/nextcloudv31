#!/usr/bin/env bash
set -euo pipefail

# =========================
# Nextcloud fully-automated installer (no prompts)
# Based on your attached instructions.xlsx sequence
# =========================

# ---- CONFIG (edit these) ----
SITE_NAME="cloud"  # Apache ServerName used in vhost
WEB_ROOT="/var/www/cloud"

NEXTCLOUD_ZIP_URL="https://download.nextcloud.com/server/releases/latest.zip"

DB_NAME="cloud"
DB_USER="cloud"
DB_PASS="clouddbadminP@ssw0rd"    # Change in production

TIMEZONE="Africa/Cairo"

# =========================
# 1) System update/full-upgrade + cleanup (as requested)
# =========================
sudo apt-get update -y && sudo apt-get full-upgrade -y && sudo apt clean && sudo apt-get autoremove -y && sudo apt autoclean

# =========================
# 2) Install MariaDB
# =========================
apt-get install -y mariadb-server
systemctl enable --now mariadb

# =========================
# 3) MariaDB hardening (approx. mysql_secure_installation choices from sheet)
# =========================
mariadb <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

# =========================
# 4) Create Nextcloud database + user
# =========================
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# =========================
# 5) Install Apache + PHP modules (as in sheet)
# =========================
apt-get install -y apache2
apt-get install -y php php-apcu php-bcmath php-cli php-common php-curl php-gd php-gmp php-imagick php-intl php-mbstring php-mysql php-zip php-xml

a2enmod dir env headers mime rewrite ssl
phpenmod bcmath gmp imagick intl
systemctl restart apache2

# =========================
# 6) Download + deploy Nextcloud
# =========================
apt-get install -y unzip wget

cd /tmp
rm -rf nextcloud cloud nextcloud.zip
wget -O nextcloud.zip "${NEXTCLOUD_ZIP_URL}"
unzip -q nextcloud.zip
rm -f nextcloud.zip

# Ensure expected folder exists
test -d /tmp/nextcloud

# Move to /var/www/cloud (sheet sequence: rename, move, chown)
rm -rf "${WEB_ROOT}"
mv /tmp/nextcloud /tmp/cloud
mv /tmp/cloud /var/www
chown -R www-data:www-data "${WEB_ROOT}"

# =========================
# 7) Configure Apache vhost (cloud.conf)
# =========================
VHOST_PATH="/etc/apache2/sites-available/${SITE_NAME}.conf"
cat > "${VHOST_PATH}" <<EOF
<VirtualHost *:80>
    DocumentRoot "${WEB_ROOT}"
    ServerName ${SITE_NAME}

    <Directory "${WEB_ROOT}">
        Options MultiViews FollowSymlinks
        AllowOverride All
        Order allow,deny
        Allow from all
    </Directory>

   TransferLog /var/log/apache2/${SITE_NAME}.log
   ErrorLog /var/log/apache2/${SITE_NAME}.log
</VirtualHost>
EOF

a2dissite 000-default.conf || true
a2ensite "${SITE_NAME}.conf"
systemctl restart apache2

# =========================
# 8) Tune php.ini (values from sheet)
# =========================
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_INI="/etc/php/${PHP_VER}/apache2/php.ini"

if [[ -f "${PHP_INI}" ]]; then
  sed -i "s~^\s*memory_limit\s*=.*~memory_limit = 1024M~" "${PHP_INI}" || true
  sed -i "s~^\s*upload_max_filesize\s*=.*~upload_max_filesize = 200M~" "${PHP_INI}" || true
  sed -i "s~^\s*post_max_size\s*=.*~post_max_size = 200M~" "${PHP_INI}" || true
  sed -i "s~^\s*max_execution_time\s*=.*~max_execution_time = 360~" "${PHP_INI}" || true
  sed -i "s~^\s*;*\s*date.timezone\s*=.*~date.timezone = ${TIMEZONE}~" "${PHP_INI}" || true

  if ! grep -q "^opcache.enable=" "${PHP_INI}"; then
    cat >> "${PHP_INI}" <<'OPCACHE'

; Added by installer
opcache.enable=1
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.validate_timestamps=0
opcache.revalidate_freq=60
OPCACHE
  fi

  systemctl restart apache2
fi

# =========================
# 9) Final output (web install still required)
# =========================
echo "Nextcloud files deployed to: ${WEB_ROOT}"
echo "Open: http://${SITE_NAME}/ (or http://<server-ip>/ if DNS/hosts not set)"
echo "DB name: ${DB_NAME}, DB user: ${DB_USER}, DB pass: (as in script)"
echo "Trusted domains can be set in: ${WEB_ROOT}/config/config.php"
