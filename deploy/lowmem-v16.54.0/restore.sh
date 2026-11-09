#!/bin/bash
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
take_lock

requested=${1:-}
[[ -n "$requested" && -d "$requested" ]] || die "用法: sudo bash restore.sh <备份目录>"
[[ -f "$requested/database.sql.gz" ]] || die "备份目录缺少 database.sql.gz"
requested=$(cd "$requested" && pwd)

copy_inbox() {
	local source_dir="$1"
	docker run --rm --user root --entrypoint bash --pull never \
		-v erpnext-lowmem-sites:/sites \
		-v "$source_dir:/restore-src:ro" \
		frappe/erpnext:v16.54.0 \
		-c 'set -euo pipefail; dest=/sites/frontend/private/restore-inbox; rm -rf "$dest"; mkdir -p "$dest"; cp -a /restore-src/. "$dest/"; chown -R 1000:1000 "$dest"; chmod -R u=rwX,go= "$dest"'
}

run_restore() {
	local source_dir="$1"
	copy_inbox "$source_dir"
	compose --profile task run --rm --no-deps restore
}

guard_snapshot
safety="$ROOT/backups/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)"
log "恢复前先做安全备份"
create_backup "$safety"

trap remove_restore_inbox EXIT
stop_app_tier
if ! run_restore "$requested"; then
	log "所请求的恢复失败，改用操作前的安全备份"
	if ! run_restore "$safety"; then
		guard_assert_stable || true
		die "安全备份恢复失败，应用层已停止，数据卷仍在"
	fi
	start_app_tier || true
	guard_assert_stable || true
	die "所请求的恢复失败，已尝试回到操作前备份"
fi

start_app_tier
bash "$ROOT/healthcheck.sh"
guard_assert_stable
log "恢复完成并通过健康检查"
