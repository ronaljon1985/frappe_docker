#!/bin/bash
# Static checks for the bundle. Creates temporary secrets and deletes them.
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

if [[ -e "$ROOT/secrets" ]]; then
	echo "拒绝在已有 secrets 目录上做静态测试" >&2
	exit 1
fi

cleanup() {
	rm -rf "$ROOT/secrets" "$ROOT/state"
}
trap cleanup EXIT

fail() {
	echo "静态检查失败: $*" >&2
	exit 1
}

python3 -m py_compile \
	"$ROOT/scripts/configure_site.py" \
	"$ROOT/scripts/render_redis_conf.py" \
	"$ROOT/scripts/redact.py" \
	"$ROOT/scripts/check_login.py" \
	"$ROOT/tests/assert_compose.py"

while IFS= read -r script; do
	bash -n "$script"
done < <(find "$ROOT" -name '*.sh' -type f | sort)

if command -v shellcheck >/dev/null; then
	find "$ROOT" -name '*.sh' -type f -print0 | xargs -0 shellcheck -x
fi

forbidden='changeit|DB_PASSWORD=123|MYSQL_ROOT_PASSWORD:[[:space:]]*admin|admin-password=admin|password=admin|github\.com|registry-1\.docker\.io|docker\.io/|apt-get|reboot|shutdown|iptables|ufw |firewall-cmd|systemctl[[:space:]]+(restart|stop|start|disable|mask)'
if grep -RInE "$forbidden" \
	"$ROOT"/*.sh \
	"$ROOT/scripts" \
	"$ROOT/tests/assert_compose.py" \
	"$ROOT/compose.yaml" \
	"$ROOT/config" \
	"$ROOT/images.lock" \
	"$ROOT/mirrors.txt"; then
	fail "发现禁止内容"
fi

if ! grep -q 'short,default,long' "$ROOT/scripts/run_worker.sh"; then
	fail "worker 没有消费全部队列"
fi
if ! grep -q 'zhenbei-escort' "$ROOT/scripts/lib.sh"; then
	fail "缺少现有服务保护"
fi

mkdir -p "$ROOT/secrets" "$ROOT/state"
chmod 700 "$ROOT/secrets" "$ROOT/state"
canary='0123456789abcdef0123456789abcdef0123456789abcdef'
printf '%s' "$canary" >"$ROOT/secrets/db_root_password"
printf '%s' "$canary" >"$ROOT/secrets/admin_password"
printf '%s' "$canary" >"$ROOT/secrets/redis_cache_password"
printf '%s' "$canary" >"$ROOT/secrets/redis_queue_password"
printf 'requirepass %s\n' "$canary" >"$ROOT/secrets/redis-cache.conf"
printf 'requirepass %s\n' "$canary" >"$ROOT/secrets/redis-queue.conf"
chmod 600 "$ROOT/secrets/"*

docker_cmd=(docker)
if ! docker info >/dev/null 2>&1; then
	if sudo docker info >/dev/null 2>&1; then
		docker_cmd=(sudo docker)
	else
		fail "docker 不可用"
	fi
fi

config_json=$("${docker_cmd[@]}" compose --profile task --project-directory "$ROOT" -f "$ROOT/compose.yaml" config --format json)
printf '%s' "$config_json" | python3 "$ROOT/tests/assert_compose.py"
if printf '%s' "$config_json" | grep -q "$canary"; then
	fail "渲染结果包含密钥"
fi
if printf '%s' "$config_json" | grep -E -q '"published": "8080"|"published": "3306"|"published": "6379"|"published": "443"'; then
	fail "渲染结果发布了禁止端口"
fi

echo "静态检查通过"
