#!/bin/bash
# ============================================================
#  REVIASYL PANEL AUTO-INSTALLER v1.0
#  Panel Reviactyl v26.10.0 + Reviactyl Agent v26.10.0
#  Tested on: Ubuntu 22.04 (should work on 24.04 too)
#
#  Pemakaian:
#    bash install-reviactyl.sh                  # panel + agent
#    bash install-reviactyl.sh --panel-only     # panel aja
#    bash install-reviactyl.sh --agent-only     # agent aja
#
#  Catatan:
#  - Admin panel: email/password di-set lewat env ADMIN_EMAIL & ADMIN_PASSWORD
#    (default: admin@changeme.local / admin12345 — GANTI SETELAH INSTALL!)
#  - Node & allocation didaftarkan otomatis pakai IP publik server.
#  - Semua konfigurasi pakai HTTP (tanpa SSL). SSL menyusul kalau sudah
#    punya domain — jalankan certbot manual atau pakai Proxy Manager ext.
# ============================================================

set -euo pipefail

# ----------------------- KONFIGURASI -----------------------
PANEL_VERSION="v26.10.0"
PANEL_URL="https://github.com/reviactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz"
AGENT_VERSION="v26.10.0"
AGENT_URL="https://github.com/reviactyl/agent/releases/download/${AGENT_VERSION}/agent_linux_amd64"

PANEL_DIR="/var/www/pterodactyl"
AGENT_CONFIG_DIR="/etc/reviactyl"
DATA_DIR="/var/lib/pterodactyl"

DB_NAME="panel"
DB_USER="ptero"
DB_PASS="${DB_PASS:-Pt3roDb_9x2KqLm7}"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@changeme.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
ADMIN_LAST="${ADMIN_LAST:-YZ}"

AGENT_PORT="8081"
SFTP_PORT="2022"
ALLOC_START="25565"
ALLOC_END="25570"

# ----------------------- WARNA -----------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ----------------------- PARSE ARGUMEN -----------------------
MODE="both"
case "${1:-}" in
  --panel-only) MODE="panel" ;;
  --agent-only) MODE="agent" ;;
  "")           MODE="both" ;;
  *) echo "Usage: $0 [--panel-only|--agent-only]"; exit 1 ;;
esac

# ----------------------- PRASYARAKAT -----------------------
[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root!"
if ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq curl ca-certificates
fi
PUBLIC_IP=$(curl -4 -s --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
[ -n "$PUBLIC_IP" ] || fail "Gagal deteksi IP publik."
info "IP publik server: ${PUBLIC_IP}"

TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
info "RAM total: ${TOTAL_RAM_MB} MB"
if [ "$TOTAL_RAM_MB" -lt 3500 ]; then
  warn "RAM < 3.5 GB — install panel masih bisa, tapi composer/artisan bisa OOM."
  warn "Kalau gagal di migrate/seed, tambah swap dulu: fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile"
fi

# ----------------------- DEPENDENSI -----------------------
install_deps() {
  info "Install dependensi sistem (PHP 8.3, MariaDB, Nginx, Redis, Docker)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq software-properties-common lsb-release apt-transport-https \
    curl unzip zip git ca-certificates gnupg

  add-apt-repository -y ppa:ondrej/php
  apt-get update -qq
  apt-get install -y -qq \
    php8.3 php8.3-cli php8.3-fpm php8.3-common php8.3-mysql php8.3-pgsql \
    php8.3-redis php8.3-mbstring php8.3-xml php8.3-bcmath php8.3-curl \
    php8.3-gd php8.3-zip php8.3-intl php8.3-sqlite3 \
    mariadb-server mariadb-client nginx redis-server

  # Composer
  if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet
  fi

  # Docker (buat agent)
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
  fi

  # Certbot (opsional, buat Proxy Manager ext / SSL nanti)
  apt-get install -y -qq certbot python3-certbot-nginx || warn "Certbot gagal — skip dulu, gak wajib."

  systemctl enable --now mariadb redis-server php8.3-fpm docker
  ok "Dependensi terpasang."
}

# ----------------------- DATABASE -----------------------
setup_db() {
  info "Setup database MariaDB..."
  # TMPDIR default /root-nya Hermes suka bikin mariadb-install-db gagal — paksa /tmp
  export TMPDIR=/tmp
  if ! mysqladmin ping --silent 2>/dev/null; then
    systemctl stop mariadb 2>/dev/null || true
    rm -rf /var/lib/mysql/*
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1
    systemctl start mariadb
  fi
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';"
  mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1'; FLUSH PRIVILEGES;"
  ok "Database ${DB_NAME} siap."
}

# ----------------------- PANEL -----------------------
install_panel() {
  info "Download & extract panel ${PANEL_VERSION}..."
  mkdir -p "${PANEL_DIR}"
  curl -sL -o /tmp/panel.tar.gz "${PANEL_URL}"
  tar -xzf /tmp/panel.tar.gz -C "${PANEL_DIR}"

  cd "${PANEL_DIR}"
  [ -f .env ] || cp .env.example .env

  info "Composer install (5-10 menit, jangan di-cancel)..."
  export COMPOSER_ALLOW_SUPERUSER=1
  composer install --no-dev --optimize-autoloader --no-interaction 2>&1 | tail -3

  info "Generate .env + APP_KEY..."
  sed -i "s|^APP_URL=.*|APP_URL=http://${PUBLIC_IP}|" .env
  sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=mariadb|" .env
  cat >> .env <<EOF
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}
CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=127.0.0.1
EOF
  php artisan key:generate --force 2>&1 | tail -1

  info "Migrate + seed database (5-10 menit)..."
  # Patch migration MariaDB 10.6 (expires_at invalid default) kalau ada
  local MIG="database/migrations/2026_08_21_000000_create_subuser_preview_sessions_table.php"
  if [ -f "$MIG" ] && grep -q "timestamp('expires_at')->index();" "$MIG"; then
    sed -i "s/timestamp('last_seen_at');/timestamp('last_seen_at')->useCurrent();/; s/timestamp('expires_at')->index();/timestamp('expires_at')->nullable()->index();/" "$MIG"
    ok "Patch migration expires_at diterapkan."
  fi
  php artisan migrate --seed --force 2>&1 | tail -3

  info "Setup environment panel + disable captcha bawaan (biar bisa login)..."
  php artisan p:environment:setup --cache=redis --session=redis --queue=redis --no-telemetry \
    --author="${ADMIN_EMAIL}" 2>&1 | tail -1
  # Captcha default 'recaptcha' pakai key demo yang pasti gagal — set disable
  if [ -f config/captcha.php ]; then
    sed -i "s/env('CAPTCHA_PROVIDER', *'recaptcha')/env('CAPTCHA_PROVIDER', 'disable')/" config/captcha.php
    php artisan config:clear >/dev/null 2>&1
  fi

  info "Buat akun admin: ${ADMIN_EMAIL}"
  php artisan p:user:make --email="${ADMIN_EMAIL}" --username="${ADMIN_USER}" \
    --name-first="${ADMIN_FIRST}" --name-last="${ADMIN_LAST}" \
    --password="${ADMIN_PASSWORD}" --admin=1 2>&1 | tail -3

  chown -R www-data:www-data "${PANEL_DIR}/storage" "${PANEL_DIR}/bootstrap/cache"
  chown -R www-data:www-data "${PANEL_DIR}"
  php artisan queue:work --stop-when-empty >/dev/null 2>&1 || true
  ok "Panel terinstall di ${PANEL_DIR}"
}

setup_nginx() {
  info "Setup Nginx..."
  cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${PUBLIC_IP};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/ptero.access.log;
    error_log  /var/log/nginx/ptero.error.log;

    client_max_body_size 100m;
    client_body_timeout 120s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
  nginx -t 2>&1 | tail -1
  systemctl restart nginx php8.3-fpm
  ok "Nginx siap."
}

setup_queue() {
  info "Setup queue worker (pteroq)..."
  cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now pteroq
  ok "Queue worker aktif."
}

# ----------------------- AGENT -----------------------
install_agent() {
  info "Download & install Reviactyl Agent ${AGENT_VERSION}..."
  curl -sL -o /usr/local/bin/agent "${AGENT_URL}"
  chmod +x /usr/local/bin/agent
  agent version

  mkdir -p "${AGENT_CONFIG_DIR}" "${DATA_DIR}/volumes" /var/run/agent

  info "Daftarkan node di panel + generate config agent..."
  # Login ke panel via session cookie, terus bikin node via API application
  local COOKIE="/tmp/.ptero_install_cookie"
  rm -f "$COOKIE"
  local CSRF
  CSRF=$(curl -s -c "$COOKIE" "http://127.0.0.1/auth/login" | grep -oP 'csrf-token" content="\K[^"]+')
  [ -n "$CSRF" ] || fail "Gagal ambil CSRF token panel. Pastikan panel sudah jalan."
  curl -s -b "$COOKIE" -c "$COOKIE" -X POST "http://127.0.0.1/auth/login" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -H "X-CSRF-TOKEN: ${CSRF}" \
    --data-raw "{\"user\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\",\"remember\":true}" \
    | grep -q '"complete":true' || fail "Login panel gagal. Cek ADMIN_EMAIL/ADMIN_PASSWORD."

  local XSRF
  XSRF=$(awk '$6=="XSRF-TOKEN"{print $7}' "$COOKIE" | tail -1)
  XSRF=$(python3 -c "import urllib.parse,sys;print(urllib.parse.unquote('${XSRF}'))")

  local LOC_ID
  LOC_ID=$(curl -s -b "$COOKIE" -X POST "http://127.0.0.1/api/application/locations" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: ${XSRF}" \
    --data-raw '{"short":"local","long":"Auto-created by installer"}' \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['attributes']['id'] if 'attributes' in d else 1)")

  # Hapus node lama dengan nama sama biar idempotent
  local NODE_EXISTS
  NODE_EXISTS=$(curl -s -b "$COOKIE" -H "X-XSRF-TOKEN: ${XSRF}" "http://127.0.0.1/api/application/nodes" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(any(n['attributes']['name']=='node-1' for n in d.get('data',[])))")
  if [ "$NODE_EXISTS" = "True" ]; then
    info "Node 'node-1' sudah ada — skip pembuatan."
  else
    curl -s -b "$COOKIE" -X POST "http://127.0.0.1/api/application/nodes" \
      -H 'Accept: application/json' -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: ${XSRF}" \
      --data-raw "{
        \"name\":\"node-1\",
        \"description\":\"Auto-created by installer\",
        \"location_id\":${LOC_ID},
        \"fqdn\":\"${PUBLIC_IP}\",
        \"scheme\":\"http\",
        \"behind_proxy\":false,
        \"memory\":$(( TOTAL_RAM_MB - 1024 )),
        \"memory_overallocate\":0,
        \"disk\":100000,
        \"disk_overallocate\":0,
        \"upload_size\":100,
        \"daemon_listen\":${AGENT_PORT},
        \"daemon_sftp\":${SFTP_PORT},
        \"daemon_base\":\"${DATA_DIR}/volumes\"
      }" | grep -q '"id"' || fail "Gagal daftarkan node di panel."
  fi

  info "Ambil konfigurasi agent dari panel..."
  curl -s -b "$COOKIE" -H "X-XSRF-TOKEN: ${XSRF}" "http://127.0.0.1/api/application/nodes/1/configuration" \
    > /tmp/agent-config.json
  python3 - <<PYEOF
import json
cfg = json.load(open('/tmp/agent-config.json'))
yaml = f"""debug: {str(cfg.get('debug', False)).lower()}
uuid: {cfg['uuid']}
token_id: {cfg['token_id']}
token: {cfg['token']}
api:
  host: {cfg['api']['host']}
  port: {cfg['api']['port']}
  ssl:
    enabled: {str(cfg['api']['ssl']['enabled']).lower()}
    cert: {cfg['api']['ssl']['cert']}
    key: {cfg['api']['ssl']['key']}
  upload_limit: {cfg['api']['upload_limit']}
system:
  data: {cfg['system']['data']}
  sftp:
    bind_port: {cfg['system']['sftp']['bind_port']}
allowed_mounts: []
remote: {cfg['remote']}
"""
open('${AGENT_CONFIG_DIR}/config.yml','w').write(yaml)
print("Agent config written.")
PYEOF

  info "Setup systemd service agent..."
  cat > /etc/systemd/system/agent.service <<EOF
[Unit]
Description=Reviactyl Agent
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=${DATA_DIR}
LimitNOFILE=4096
PIDFile=/var/run/agent/agent.pid
ExecStart=/usr/local/bin/agent --config=${AGENT_CONFIG_DIR}/config.yml
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now agent
  sleep 3
  systemctl is-active agent >/dev/null && ok "Agent aktif." || fail "Agent gagal start — cek: journalctl -u agent -n 20"

  info "Buat allocation game ports ${ALLOC_START}-${ALLOC_END}..."
  curl -s -b "$COOKIE" -X POST "http://127.0.0.1/api/application/nodes/1/allocations" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' -H "X-XSRF-TOKEN: ${XSRF}" \
    --data-raw "{\"ip\":\"${PUBLIC_IP}\",\"alias\":null,\"ports\":[\"${ALLOC_START}-${ALLOC_END}\"]}" \
    -o /dev/null -w "%{http_code}" | grep -qE '20[04]|201' || warn "Allocation gagal (mungkin sudah ada)."

  rm -f "$COOKIE"
  ok "Agent + node + allocation siap."
}

# ----------------------- MAIN -----------------------
# ----------------------- EXTENSIONS -----------------------
# Download .rext dari repo GitHub + install semua
EXT_REPO_BASE="https://raw.githubusercontent.com/agusrizal17/auto-reviactyl/main"
EXTENSIONS=(
  "egg-changer.zip:egg-changer"
  "proxy-managerV2.zip:proxy-manager"
  "datapack-manager.zip:datapack-manager"
  "PacMan.rext.zip:pacman"
)

install_extensions() {
  info "Install extensions dari repo agusrizal17/auto-reviactyl..."
  mkdir -p /tmp/exts
  local any_failed=0

  for entry in "${EXTENSIONS[@]}"; do
    local zip_file="${entry%%:*}"
    local ext_id="${entry##*:}"
    local zip_url="${EXT_REPO_BASE}/${zip_file}"

    info "  Download ${zip_file}..."
    if ! curl -fsSL -o "/tmp/exts/${zip_file}" "${zip_url}"; then
      warn "  Gagal download ${zip_file} — skip."
      any_failed=1
      continue
    fi

    # Extract: cari file .rext di dalam zip (bisa di root atau di dalam subfolder)
    rm -rf "/tmp/exts/${ext_id}" && mkdir -p "/tmp/exts/${ext_id}"
    unzip -oq "/tmp/exts/${zip_file}" -d "/tmp/exts/${ext_id}"
    local rext_file
    rext_file=$(find "/tmp/exts/${ext_id}" -name "*.rext" -type f | head -1)
    if [ -z "$rext_file" ]; then
      warn "  ${zip_file} tidak berisi file .rext — skip."
      any_failed=1
      continue
    fi

    info "  Install extension: ${ext_id}"
    cd "${PANEL_DIR}"
    php artisan extensions:install "${rext_file}" 2>&1 | tail -1 || { warn "  Install ${ext_id} gagal."; any_failed=1; continue; }
    php artisan extensions:enable "${ext_id}" 2>&1 | tail -1 || true
  done

  # Sudoers untuk Proxy Manager (kalau extension-nya terinstall)
  if [ -d "${PANEL_DIR}/extensions/proxy-manager" ]; then
    info "  Setup sudoers untuk Proxy Manager..."
    cat > /etc/sudoers.d/proxy-manager <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/sbin/nginx -t
www-data ALL=(root) NOPASSWD: /bin/systemctl reload nginx
www-data ALL=(root) NOPASSWD: /usr/bin/certbot --nginx -d *
www-data ALL=(root) NOPASSWD: /bin/ln -sf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
www-data ALL=(root) NOPASSWD: /bin/cp /var/www/pterodactyl/extensions/proxy-manager/data/generated/*.conf /etc/nginx/sites-available/*.conf
www-data ALL=(root) NOPASSWD: /bin/rm /etc/nginx/sites-enabled/*.conf
SUDOEOF
    chmod 440 /etc/sudoers.d/proxy-manager
    visudo -c >/dev/null 2>&1 || warn "Sudoers syntax error — cek: visudo -c"
  fi

  cd "${PANEL_DIR}"
  php artisan optimize:clear >/dev/null 2>&1
  chown -R www-data:www-data extensions storage bootstrap/cache public/extensions 2>/dev/null

  if [ "$any_failed" -eq 0 ]; then
    ok "Semua extensions terinstall."
  else
    warn "Beberapa extensions gagal — cek log di atas."
  fi

  rm -rf /tmp/exts
  info "Extension list:"
  php artisan extensions:list 2>/dev/null | tail -n +2 || true
}

echo ""
echo "======================================"
echo "  REVIASYL PANEL AUTO-INSTALLER"
echo "  Panel ${PANEL_VERSION} + Agent ${AGENT_VERSION}"
echo "======================================"
echo ""
[ "$MODE" = "panel" ] || [ "$MODE" = "both" ] && install_deps
[ "$MODE" = "panel" ] || [ "$MODE" = "both" ] && setup_db

case "$MODE" in
  panel) install_panel; setup_nginx; setup_queue; install_extensions ;;
  agent) install_agent ;;
  both)  install_panel; setup_nginx; setup_queue; install_extensions; install_agent ;;
esac

echo ""
echo "======================================"
ok "SELESAI!"
echo ""
echo "  Panel  : http://${PUBLIC_IP}"
echo "  Login  : ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
echo "  Agent  : port ${AGENT_PORT} (systemd: agent)"
echo "  Queue  : systemd: pteroq"
echo "  Ext    : egg-changer, proxy-manager, datapack-manager, pacman"
echo ""
warn "  >>> GANTI password admin setelah login pertama! <<<"
warn "  >>> Masih HTTP tanpa SSL — pasang domain + certbot kalau mau produksi."
echo "======================================"
