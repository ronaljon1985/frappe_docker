#!/bin/bash
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
guard_assert_alive
assert_frontend_port
assert_datastores_are_private

for svc in db redis-cache redis-queue backend frontend websocket; do
	wait_healthy "$svc" 60
done
for svc in worker scheduler; do
	cid=$(compose ps -q "$svc")
	[[ -n "$cid" ]] || die "$svc 没有容器"
	status=$(docker inspect --format '{{.State.Status}}' "$cid")
	[[ "$status" == "running" ]] || die "$svc 状态是 $status"
done

apps=$(compose exec -T backend bench --site frontend list-apps)
printf '%s\n' "$apps" | grep -q '^erpnext[[:space:]]' || die "站点未安装 erpnext"
printf '%s\n' "$apps" | grep -q '^frappe[[:space:]]' || die "站点未安装 frappe"
log "已安装应用: $(printf '%s' "$apps" | tr '\n' ' ')"

scheduler_status=$(compose exec -T backend bench --site frontend scheduler status)
printf '%s\n' "$scheduler_status" | python3 -c 'import sys; text=sys.stdin.read().lower(); sys.exit(0 if "disabled" not in text and "enabled" in text else 1)' || die "调度器未启用"
log "调度器状态已确认"

doctor_ok=0
attempt=0
while [[ "$attempt" -lt 12 ]]; do
	if compose exec -T backend bench doctor --site frontend >"$ROOT/state/doctor.raw" 2>&1; then
		doctor_ok=1
		break
	fi
	attempt=$((attempt + 1))
	sleep 5
done
python3 "$ROOT/scripts/redact.py" "$ROOT/secrets" <"$ROOT/state/doctor.raw" >"$ROOT/state/doctor.txt" || true
rm -f "$ROOT/state/doctor.raw"
chmod 600 "$ROOT/state/doctor.txt" || true
[[ "$doctor_ok" -eq 1 ]] || die "bench doctor 未通过，详见 state/doctor.txt"

socket_body=$(mktemp "$ROOT/state/socketio.XXXXXX")
socket_code=$(curl -sS -o "$socket_body" -w '%{http_code}' --max-time 20 'http://127.0.0.1/socket.io/?EIO=4&transport=polling' || true)
python3 - "$socket_body" "$socket_code" <<'PY'
import pathlib
import sys

body_path = pathlib.Path(sys.argv[1])
code = sys.argv[2]
body = body_path.read_bytes()
body_path.unlink(missing_ok=True)
if code != "200" or not body.startswith(b"0"):
    raise SystemExit(1)
PY
log "websocket 轮询握手通过"
python3 "$ROOT/scripts/check_login.py" "$ROOT" "http://127.0.0.1"
log "健康检查通过"
