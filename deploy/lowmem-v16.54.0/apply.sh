#!/bin/bash
# Install the low-memory ERPNext stack. Refuses to continue if port 8080 changes.
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
export ERP_BUNDLE_IN_APPLY=1
export ROLLBACK_IN_PROGRESS=0
phase_started=0

on_exit() {
	local code="$1"
	if [[ "$code" -ne 0 && "$phase_started" -eq 1 && "${ROLLBACK_IN_PROGRESS:-0}" != "1" ]]; then
		export ROLLBACK_IN_PROGRESS=1
		log "部署失败，开始隔离回滚并保留数据卷"
		bash "$ROOT/rollback.sh" || log "回滚脚本返回非零"
	fi
}
trap 'on_exit $?' EXIT

take_lock
run_preflight
guard_snapshot
render_secrets
pull_images
guard_assert_stable
assert_rendered_compose_has_no_secrets
guard_assert_stable

phase_started=1
log "启动数据库和 Redis"
compose up -d --no-deps db redis-cache redis-queue
wait_healthy db 300
wait_healthy redis-cache 120
wait_healthy redis-queue 120
guard_assert_stable
assert_datastores_are_private

run_oneshot configurator
guard_assert_stable
run_oneshot create-site
guard_assert_stable

log "启动应用进程"
start_app_tier
assert_frontend_port
assert_datastores_are_private
guard_assert_stable
bash "$ROOT/healthcheck.sh"
guard_assert_stable

log "部署完成。站点 frontend，访问 http://<服务器IP>/ ，管理员用户 Administrator。"
log "管理员密码文件: $ROOT/secrets/admin_password"
log "数据库 root 密码文件: $ROOT/secrets/db_root_password"
log "密码只在服务器上由 root 读取，脚本不会显示。"
