#!/usr/bin/env bash
set -euo pipefail

# =========================
# Nextcloud "single-click" installer
# Based on the sequence in the attached instructions.xlsx
# =========================

# ---- CONFIG (edit these) ----
SITE_NAME="cloud"                     # Apache ServerName used in vhost
WEB_ROOT="/var/www/cloud"             # Nextcloud directory
NEXTCLOUD_ZIP_URL="https://download.nextcloud.com/server/releases/nextcloud-31.0.6.zip"

DB_NAME="cloud"
DB_USER="cloud"
DB_PASS="clouddbadminP@ssw0rd"        # Consider changing; stored in shell history if typed here

TIMEZONE="Africa/Cairo"

# ---- Helpers ----
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (e.g., sudo bash $0)"
    exit 1
  fi
}

pause() {
  read -r -p "Press ENTER to continue..."
}

require_root

echo "== 1) System update/upgrade =="
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

echo
echo "== 2) Hostname/hosts edits (manual in your sheet) =="
echo "Your sheet uses: nano /etc/hostname and nano /etc/hosts"
echo "If you need to change them, do it now in another SSH session."
pause

echo
echo "== 3) Install MariaDB =="
apt-get install -y mariadb-server
systemctl enable --now mariadb
systemctl status mariadb --no-pager || true

echo
echo "== 4) MariaDB 'secure installation' equivalent (non-interactive) =="
# The sheet runs mysql_secure_installation with:
# - Switch to unix_socket auth: YES
# - Change root password: NO
# - Remove anonymous users: YES
# - Disallow root remote login: YES
# - Remove test database: YES
# - Reload privileges: YES
#
# This block applies similar hardening using SQL.
mariadb <<'SQL'
-- Use unix_socket for root (common default on Ubuntu/MariaDB).
-- If this fails on your distro/version, adjust manually.
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;

-- Remove anonymous users:
DELETE FROM mysql.user WHERE User='';

-- Disallow remote root login:
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');

-- Remove test database:
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';

FLUSH PRIVILEGES;
SQL

echo
echo "== 5) Create Nextcloud database and user =="
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo
echo "== 6) Install Apache + PHP modules (as in your sheet) =="
apt-get install -y apache2
apt-get install -y php php-apcu php-bcmath php-cli php-common php-curl php-gd php-gmp php-imagick php-intl php-mbstring php-mysql php-zip php-xml

a2enmod dir env headers mime rewrite ssl
phpenmod bcmath gmp imagick intl
systemctl restart apache2

echo
echo "== 7) Download + deploy Nextcloud =="
apt-get install -y unzip wget

cd /tmp
rm -f nextcloud-*.zip
wget -O nextcloud.zip "${NEXTCLOUD_ZIP_URL}"

rm -rf nextcloud
unzip -q nextcloud.zip
rm -f nextcloud.zip

# rename/move like the sheet does (nextcloud -> cloud -> /var/www)
rm -rf "${WEB_ROOT}"
mv nextcloud cloud
mv cloud /var/www

chown -R www-data:www-data "${WEB_ROOT}"
ls -l /var/www || true

echo
echo "== 8) Configure Apache vhost (cloud.conf) =="
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

echo
echo "== 9) Tune php.ini (based on your sheet values) =="
PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_INI="/etc/php/${PHP_VER}/apache2/php.ini"

if [[ -f "${PHP_INI}" ]]; then
  # Update settings (idempotent-ish replacements)
  sed -i "s~^\s*memory_limit\s*=.*~memory_limit = 1024M~" "${PHP_INI}" || true
  sed -i "s~^\s*upload_max_filesize\s*=.*~upload_max_filesize = 200M~" "${PHP_INI}" || true
  sed -i "s~^\s*post_max_size\s*=.*~post_max_size = 200M~" "${PHP_INI}" || true
  sed -i "s~^\s*max_execution_time\s*=.*~max_execution_time = 360~" "${PHP_INI}" || true
  sed -i "s~^\s*;*\s*date.timezone\s*=.*~date.timezone = ${TIMEZONE}~" "${PHP_INI}" || true

  # OPCache settings (append if missing)
  grep -q "^opcache.enable=" "${PHP_INI}" || cat >> "${PHP_INI}" <<'OPCACHE'

; Added by installer
opcache.enable=1
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.validate_timestamps=0
opcache.revalidate_freq=60
OPCACHE

  systemctl restart apache2
else
  echo "WARNING: php.ini not found at ${PHP_INI}; adjust manually."
fi

echo
echo "== 10) Nextcloud web installer (manual) =="
echo "Open: http://${SITE_NAME}/"
echo "Admin user/password: (your sheet uses cloud/cloud)"
echo "DB: ${DB_NAME}  User: ${DB_USER}  Pass: (as configured)"
echo "After finishing the web installer, you can add trusted domains in:"
echo "  ${WEB_ROOT}/config/config.php"
pause

echo
echo "Done."
echo "Note: Your sheet includes a reboot step; reboot if needed: sudo reboot"
