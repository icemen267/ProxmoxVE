#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster) | MickLesk (CanbiZ)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://docs.paperless-ngx.com/ | Github: https://github.com/paperless-ngx/paperless-ngx
#
# ANGEPASST: installiert fest Paperless-ngx v2.15.2 (fuer Import eines alten Exports)
# Aenderungen gegenueber Upstream:
#   - Version fest auf v2.15.2 statt "latest"
#   - Python 3.13 bewusst beibehalten: der uv.lock von v2.15.2 zieht fuer Python 3.12
#     Sonder-Wheels (zxing-cpp, psycopg-c) von paperless-ngx/builder, deren Hash
#     inzwischen nicht mehr passt. Mit 3.13 kommen diese Pakete regulaer von PyPI.
#   - psycopg[binary] statt psycopg-c (siehe Kommentar bei uv sync)
#   - kein admin-Benutzer, da die Benutzer mit dem Import kommen

PAPERLESS_VERSION="v2.15.2"

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies (Patience)"
$STD apt install -y \
  redis \
  build-essential \
  imagemagick \
  fonts-liberation \
  gnupg \
  optipng \
  libpq-dev \
  libmagic-dev \
  poppler-utils \
  default-libmysqlclient-dev \
  automake \
  libtool \
  pkg-config \
  libtiff-dev \
  libpng-dev \
  libleptonica-dev \
  unpaper \
  icc-profiles-free \
  qpdf \
  libleptonica6 \
  libxml2 \
  pngquant \
  zlib1g \
  tesseract-ocr \
  tesseract-ocr-eng \
  ghostscript
msg_ok "Installed Dependencies"

PG_VERSION="18" setup_postgresql
PG_DB_NAME="paperlessdb" PG_DB_USER="paperless" setup_postgresql_db
fetch_and_deploy_gh_release "paperless" "paperless-ngx/paperless-ngx" "prebuild" "$PAPERLESS_VERSION" "/opt/paperless" "paperless*tar.xz"
PYTHON_VERSION="3.13" UV_PROJECT_DIR="/opt/paperless" setup_uv

msg_info "Setup Paperless-ngx $PAPERLESS_VERSION"
cd /opt/paperless
rm -rf /opt/paperless/docker
# Extra "postgres" wuerde psycopg-c 3.2.5 aus dem Quellcode bauen, das kompiliert nicht
# gegen die PostgreSQL-18-Header. Stattdessen psycopg[binary] in gleicher Version (fertiges Wheel).
$STD uv sync --extra webserver --python 3.13
$STD uv pip install "psycopg[binary]==3.2.5"
mkdir -p /opt/paperless_data/{consume,data,media,trash}
mkdir -p /opt/paperless/static
SECRET_KEY="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)"
cat <<EOF >~/paperless-ngx.creds

Paperless-ngx Version: $PAPERLESS_VERSION
Paperless-ngx Secret Key: $SECRET_KEY
Paperless-ngx DB Password: $PG_DB_PASS
Hinweis: Kein WebUI-Benutzer angelegt - die Benutzer kommen mit dem Import.
Admin manuell anlegen: cd /opt/paperless/src && set -a && . /opt/paperless/paperless.conf && set +a && uv run --no-sync -- python manage.py createsuperuser
EOF
sed -i \
  -e 's|#PAPERLESS_REDIS=redis://localhost:6379|PAPERLESS_REDIS=redis://localhost:6379|' \
  -e "s|#PAPERLESS_CONSUMPTION_DIR=../consume|PAPERLESS_CONSUMPTION_DIR=/opt/paperless_data/consume|" \
  -e "s|#PAPERLESS_DATA_DIR=../data|PAPERLESS_DATA_DIR=/opt/paperless_data/data|" \
  -e "s|#PAPERLESS_MEDIA_ROOT=../media|PAPERLESS_MEDIA_ROOT=/opt/paperless_data/media|" \
  -e "s|#PAPERLESS_EMPTY_TRASH_DIR=|PAPERLESS_EMPTY_TRASH_DIR=/opt/paperless_data/trash|" \
  -e "s|#PAPERLESS_STATICDIR=../static|PAPERLESS_STATICDIR=/opt/paperless/static|" \
  -e 's|#PAPERLESS_DBHOST=localhost|PAPERLESS_DBENGINE=postgresql\nPAPERLESS_DBHOST=localhost|' \
  -e 's|#PAPERLESS_DBPORT=5432|PAPERLESS_DBPORT=5432|' \
  -e "s|#PAPERLESS_DBNAME=paperless|PAPERLESS_DBNAME=$PG_DB_NAME|" \
  -e "s|#PAPERLESS_DBUSER=paperless|PAPERLESS_DBUSER=$PG_DB_USER|" \
  -e "s|#PAPERLESS_DBPASS=paperless|PAPERLESS_DBPASS=$PG_DB_PASS|" \
  -e "s|PAPERLESS_SECRET_KEY=change-me|PAPERLESS_SECRET_KEY=$SECRET_KEY|" \
  /opt/paperless/paperless.conf
cd /opt/paperless/src
set -a
. /opt/paperless/paperless.conf
set +a
$STD uv run -- python manage.py migrate
msg_ok "Setup Paperless-ngx $PAPERLESS_VERSION"

setup_nltk "snowball_data stopwords punkt_tab" "/usr/share/nltk_data"
for policy_file in /etc/ImageMagick-6/policy.xml /etc/ImageMagick-7/policy.xml; do
  if [[ -f "$policy_file" ]]; then
    sed -i -e 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' "$policy_file"
  fi
done

msg_info "Creating Services"
cat <<EOF >/etc/systemd/system/paperless-scheduler.service
[Unit]
Description=Paperless Celery beat
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=uv run --no-sync -- celery --app paperless beat --loglevel INFO

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/paperless-task-queue.service
[Unit]
Description=Paperless Celery Workers
Requires=redis.service
After=postgresql.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=uv run --no-sync -- celery --app paperless worker --loglevel INFO

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/paperless-consumer.service
[Unit]
Description=Paperless consumer
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStartPre=/bin/sleep 2
ExecStart=uv run --no-sync -- python manage.py document_consumer

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF >/etc/systemd/system/paperless-webserver.service
[Unit]
Description=Paperless webserver
After=network.target
Wants=network.target
Requires=redis.service

[Service]
WorkingDirectory=/opt/paperless/src
ExecStart=uv run --no-sync -- granian --interface asginl --ws --loop uvloop "paperless.asgi:application"
Environment=GRANIAN_HOST=::
Environment=GRANIAN_PORT=8000
Environment=GRANIAN_WORKERS=1

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now paperless-webserver paperless-scheduler paperless-task-queue paperless-consumer
msg_ok "Created Services"

read -r -p "${TAB3}Would you like to add Adminer? <y/N> " prompt
if [[ "${prompt,,}" =~ ^(y|yes)$ ]]; then
  setup_adminer
fi

motd_ssh
customize
cleanup_lxc
