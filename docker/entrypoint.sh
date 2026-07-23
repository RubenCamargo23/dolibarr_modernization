#!/bin/bash
# Production entrypoint for ECS. Regenerates conf.php from the container's
# env vars on every boot (Fargate's filesystem is ephemeral — the install
# wizard's one-time job is only the DB schema in RDS, not this file).
set -euo pipefail

: "${DOLI_DB_SERVER:?DOLI_DB_SERVER must be set}"
: "${DOLI_DB_USER:?DOLI_DB_USER must be set}"
: "${DOLI_DB_PASSWORD:?DOLI_DB_PASSWORD must be set}"

CONF_FILE=/var/www/html/conf/conf.php

cat > "$CONF_FILE" <<PHP
<?php
// Generated at container startup from environment variables. Do not edit —
// changes are lost on the next restart. See docker/entrypoint.sh.
\$dolibarr_main_url_root='${DOLI_URL_ROOT:-http://localhost}';
\$dolibarr_main_document_root='/var/www/html';
\$dolibarr_main_url_root_alt='/custom';
\$dolibarr_main_document_root_alt='/var/www/html/custom';
\$dolibarr_main_data_root='/var/www/documents';
\$dolibarr_main_db_host='${DOLI_DB_SERVER}';
\$dolibarr_main_db_port='${DOLI_DB_PORT:-3306}';
\$dolibarr_main_db_name='${DOLI_DATABASE:-dolibarr}';
\$dolibarr_main_db_prefix='llx_';
\$dolibarr_main_db_user='${DOLI_DB_USER}';
\$dolibarr_main_db_pass='${DOLI_DB_PASSWORD}';
\$dolibarr_main_db_type='mysqli';
\$dolibarr_main_db_character_set='utf8mb4';
\$dolibarr_main_db_collation='utf8mb4_unicode_ci';
PHP

chown www-data:www-data "$CONF_FILE"
chmod 640 "$CONF_FILE"

mkdir -p /var/www/documents/install
chown -R www-data:www-data /var/www/documents

exec apache2-foreground
