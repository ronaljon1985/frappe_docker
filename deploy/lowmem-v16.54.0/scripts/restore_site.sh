#!/bin/bash
# Restore one backup set already copied into the sites volume.
set +x
set -euo pipefail

# shellcheck disable=SC1091
source /opt/bundle-scripts/container_common.sh

inbox=${RESTORE_INBOX:-/home/frappe/frappe-bench/sites/frontend/private/restore-inbox}
cd /home/frappe/frappe-bench
wait_tcp db 3306 240
wait_tcp redis-cache 6379 120
wait_tcp redis-queue 6379 120

sql=$(find "$inbox" -maxdepth 1 -type f -name '*database.sql.gz' -print -quit)
public_files=$(find "$inbox" -maxdepth 1 -type f -name '*files.tar' ! -name '*private-files.tar' -print -quit)
private_files=$(find "$inbox" -maxdepth 1 -type f -name '*private-files.tar' -print -quit)
if [[ -z "$sql" ]]; then
	echo "备份目录中没有 database.sql.gz" >&2
	exit 1
fi

db_pass=$(</run/secrets/db_root_password)
args=(
	bench --site frontend restore
	--force
	--db-root-username root
	--db-root-password "$db_pass"
	"$sql"
)
if [[ -n "$public_files" ]]; then
	args+=(--with-public-files "$public_files")
fi
if [[ -n "$private_files" ]]; then
	args+=(--with-private-files "$private_files")
fi

set -o pipefail
"${args[@]}" 2>&1 | python3 /opt/bundle-scripts/redact.py /run/secrets
unset db_pass
enable_site_scheduler
echo "restore finished"
