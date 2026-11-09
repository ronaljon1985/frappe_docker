#!/bin/bash
# Stop only this stack. Volumes stay unless --purge-volumes is explicitly confirmed.
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
if [[ "${ERP_BUNDLE_IN_APPLY:-0}" != "1" ]]; then
	take_lock
	guard_snapshot
fi

purge=0
if [[ "${1:-}" == "--purge-volumes" ]]; then
	[[ "${ERP_BUNDLE_PURGE_CONFIRM:-}" == "erpnext-lowmem" ]] || die "拒绝删除数据卷。需要 ERP_BUNDLE_PURGE_CONFIRM=erpnext-lowmem"
	purge=1
elif [[ -n "${1:-}" ]]; then
	die "未知参数: $1"
fi

log "隔离回滚本栈，不操作系统其他服务"
if [[ "$purge" -eq 1 ]]; then
	compose down --remove-orphans --volumes --timeout 40 || log "compose down --volumes 返回非零"
	for volume in erpnext-lowmem-db-data erpnext-lowmem-sites erpnext-lowmem-logs erpnext-lowmem-redis-queue-data; do
		docker volume rm "$volume" >/dev/null 2>&1 || true
	done
else
	compose down --remove-orphans --timeout 40 || log "compose down 返回非零"
fi

mapfile -t leftover < <(docker ps -aq --filter label=com.bdks.stack=erpnext-lowmem)
if ((${#leftover[@]} > 0)); then
	docker stop --timeout 40 "${leftover[@]}" >/dev/null 2>&1 || true
	docker rm "${leftover[@]}" >/dev/null 2>&1 || true
fi
docker network rm erpnext-lowmem-data erpnext-lowmem-app >/dev/null 2>&1 || true

guard_assert_stable
if [[ "$purge" -eq 1 ]]; then
	log "已停止本栈并删除本栈数据卷。8080 基线未变化。"
else
	log "已停止本栈并保留数据卷。8080 基线未变化。"
fi
