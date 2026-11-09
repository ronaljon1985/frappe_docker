#!/bin/bash
# Create the IP-accessible site once. Passwords stay in secret files.
set +x
set -euo pipefail

# shellcheck disable=SC1091
source /opt/bundle-scripts/container_common.sh

cd /home/frappe/frappe-bench
wait_tcp db 3306 240
wait_tcp redis-cache 6379 120
wait_tcp redis-queue 6379 120

python3 - <<'PY'
import json
import sys
import time
from pathlib import Path

config = Path("/home/frappe/frappe-bench/sites/common_site_config.json")
deadline = time.time() + 120
while time.time() < deadline:
    if config.exists() and config.stat().st_size > 0:
        data = json.loads(config.read_text(encoding="utf-8"))
        if data.get("db_host") and data.get("redis_cache") and data.get("redis_queue"):
            raise SystemExit(0)
    time.sleep(2)
print("common_site_config.json was not ready", file=sys.stderr)
raise SystemExit(1)
PY

db_pass=$(</run/secrets/db_root_password)
admin_pass=$(</run/secrets/admin_password)

if [[ -f sites/frontend/site_config.json ]]; then
	apps=$(bench --site frontend list-apps)
	if printf '%s\n' "$apps" | grep -q '^erpnext[[:space:]]'; then
		echo "site frontend already has erpnext"
		enable_site_scheduler
		exit 0
	fi
	echo "站点目录已存在但 ERPNext 未安装完成。本脚本不会自动删除站点。" >&2
	exit 1
fi

bench new-site \
	--mariadb-user-host-login-scope='%' \
	--db-root-username=root \
	--db-root-password="$db_pass" \
	--admin-password="$admin_pass" \
	--install-app erpnext \
	--set-default \
	frontend 2>&1 | python3 /opt/bundle-scripts/redact.py /run/secrets
unset db_pass admin_pass

printf 'frontend\n' >sites/currentsite.txt
enable_site_scheduler
echo "site frontend created"
