#!/bin/bash
# Host-side helpers. Do not print secret file contents.
set +x
set -euo pipefail

export COMPOSE_MENU=0
export DOCKER_CLI_HINTS=false

die() {
	printf '%s 错误: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
	if [[ -n "${ROOT:-}" ]]; then
		mkdir -p "$ROOT/state"
		chmod 700 "$ROOT/state"
		printf '%s 错误: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$ROOT/state/apply.log"
	fi
	exit 1
}

log() {
	local line
	line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
	printf '%s\n' "$line" >&2
	if [[ -n "${ROOT:-}" ]]; then
		mkdir -p "$ROOT/state"
		chmod 700 "$ROOT/state"
		printf '%s\n' "$line" >>"$ROOT/state/apply.log"
	fi
}

require_root() {
	[[ "$(id -u)" -eq 0 ]] || die "请用 root 运行：sudo bash $0"
	[[ -n "${ROOT:-}" && -f "$ROOT/compose.yaml" ]] || die "部署目录不正确"
	case "$ROOT" in
	/opt/zhenbei-escort | /opt/zhenbei-escort/*)
		die "拒绝在 /opt/zhenbei-escort 内写入"
		;;
	esac
	umask 077
}

take_lock() {
	mkdir -p "$ROOT/state"
	chmod 700 "$ROOT/state"
	exec 9>"$ROOT/state/bundle.lock"
	if ! flock -n 9; then
		die "另一个部署脚本正在运行"
	fi
}

compose() {
	docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" "$@"
}

version_ge() {
	python3 - "$1" "$2" <<'PY'
import sys

def parse(value):
    value = value.split("+", 1)[0].split("-", 1)[0]
    parts = []
    for part in value.split("."):
        digits = ""
        for char in part:
            if char.isdigit():
                digits += char
            else:
                break
        if digits == "":
            break
        parts.append(int(digits))
    return tuple(parts)

left = parse(sys.argv[1])
right = parse(sys.argv[2])
width = max(len(left), len(right))
left += (0,) * (width - len(left))
right += (0,) * (width - len(right))
sys.exit(0 if left >= right else 1)
PY
}

http_code() {
	local code
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true)
	if [[ ! "$code" =~ ^[0-9]{3}$ ]]; then
		code=000
	fi
	printf '%s' "$code"
}

listener_pid() {
	ss -H -lptn "sport = :$1" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

collect_guard() {
	local code pid
	code=$(http_code "http://127.0.0.1:8080/")
	pid=$(listener_pid 8080 || true)
	[[ "$code" == "200" ]] || die "127.0.0.1:8080 返回 ${code}，期望 200"
	[[ -n "$pid" ]] || die "无法确定 8080 的监听进程"
	printf 'code=%s\n' "$code"
	printf 'pid=%s\n' "$pid"
	if [[ "${ERP_BUNDLE_LAB:-0}" == "1" ]]; then
		printf 'lab=1\n'
		printf 'unit_state=skipped\n'
		printf 'unit_pid=skipped\n'
		printf 'unit_sha256=skipped\n'
		printf 'unit_path=skipped\n'
		printf 'dir_inode=skipped\n'
		return 0
	fi
	local unit_state unit_pid unit_path unit_sha dir_inode
	unit_state=$(systemctl is-active zhenbei-escort || true)
	[[ "$unit_state" == "active" ]] || die "zhenbei-escort 不是 active（当前: ${unit_state:-unknown}）"
	unit_pid=$(systemctl show -p MainPID --value zhenbei-escort)
	unit_path=$(systemctl show -p FragmentPath --value zhenbei-escort)
	[[ -n "$unit_pid" && "$unit_pid" != "0" ]] || die "zhenbei-escort 没有 MainPID"
	[[ -f "$unit_path" ]] || die "找不到 zhenbei-escort 单元文件"
	[[ -d /opt/zhenbei-escort ]] || die "缺少 /opt/zhenbei-escort"
	unit_sha=$(sha256sum "$unit_path" | awk '{print $1}')
	dir_inode=$(stat -c '%d:%i' /opt/zhenbei-escort)
	printf 'lab=0\n'
	printf 'unit_state=%s\n' "$unit_state"
	printf 'unit_pid=%s\n' "$unit_pid"
	printf 'unit_sha256=%s\n' "$unit_sha"
	printf 'unit_path=%s\n' "$unit_path"
	printf 'dir_inode=%s\n' "$dir_inode"
}

guard_snapshot() {
	mkdir -p "$ROOT/state"
	chmod 700 "$ROOT/state"
	collect_guard >"$ROOT/state/guard.snapshot"
	chmod 600 "$ROOT/state/guard.snapshot"
	log "已记录 8080 基线"
}

guard_assert_stable() {
	[[ -f "$ROOT/state/guard.snapshot" ]] || die "缺少 8080 基线"
	local current
	current=$(mktemp "$ROOT/state/guard.current.XXXXXX")
	collect_guard >"$current"
	if ! cmp -s "$ROOT/state/guard.snapshot" "$current"; then
		diff -u "$ROOT/state/guard.snapshot" "$current" >&2 || true
		rm -f "$current"
		die "现有 8080 服务状态发生变化，停止操作"
	fi
	rm -f "$current"
}

guard_assert_alive() {
	collect_guard >/dev/null
	log "8080 存活检查通过"
}

each_image() {
	local line key local_ref repository tag index_digest amd64_digest
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue
		read -r key local_ref repository tag index_digest amd64_digest <<<"$line"
		[[ -n "${amd64_digest:-}" ]] || die "images.lock 行无效"
		[[ "$index_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "索引摘要无效: $key"
		[[ "$amd64_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "amd64 摘要无效: $key"
		"$@" "$key" "$local_ref" "$repository" "$tag" "$index_digest" "$amd64_digest"
	done <"$ROOT/images.lock"
}

image_repo_digests() {
	docker image inspect --format '{{json .RepoDigests}}' "$1" 2>/dev/null || true
}

digest_matches() {
	local ref="$1"
	shift
	local have digest
	have=$(image_repo_digests "$ref")
	[[ -n "$have" && "$have" != "[]" && "$have" != "null" ]] || return 1
	for digest in "$@"; do
		[[ "$have" == *"$digest"* ]] && return 0
	done
	return 1
}

assert_linux_amd64() {
	local arch
	arch=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1")
	[[ "$arch" == "linux/amd64" ]] || die "镜像 $1 架构是 $arch，需要 linux/amd64"
}

pull_one() {
	local key="$1" local_ref="$2" repository="$3" tag="$4" index_digest="$5" amd64_digest="$6"
	if docker image inspect "$local_ref" >/dev/null 2>&1; then
		if digest_matches "$local_ref" "$index_digest" "$amd64_digest"; then
			assert_linux_amd64 "$local_ref"
			log "本地镜像摘要匹配: $local_ref"
			return 0
		fi
		die "本地镜像 $local_ref 与锁定摘要不一致，拒绝覆盖。RepoDigests=$(image_repo_digests "$local_ref")"
	fi
	local mirror variant short pulled=0
	while IFS= read -r mirror || [[ -n "$mirror" ]]; do
		[[ "$mirror" =~ ^[[:space:]]*# ]] && continue
		[[ "$mirror" =~ ^[[:space:]]*$ ]] && continue
		local candidates=("${mirror}/${repository}:${tag}" "${mirror}/${repository}@${index_digest}" "${mirror}/${repository}@${amd64_digest}")
		if [[ "$repository" == library/* ]]; then
			short="${repository#library/}"
			candidates+=("${mirror}/${short}:${tag}" "${mirror}/${short}@${index_digest}" "${mirror}/${short}@${amd64_digest}")
		fi
		for variant in "${candidates[@]}"; do
			log "拉取 $variant"
			if timeout 300 docker pull "$variant"; then
				if digest_matches "$variant" "$index_digest" "$amd64_digest"; then
					docker tag "$variant" "$local_ref"
					assert_linux_amd64 "$local_ref"
					log "摘要匹配并标记为 $local_ref"
					pulled=1
					break
				fi
				log "已拉取但摘要不匹配，不使用: $variant"
			else
				log "拉取失败: $variant"
			fi
		done
		[[ "$pulled" -eq 1 ]] && break
	done <"$ROOT/mirrors.txt"
	[[ "$pulled" -eq 1 ]] || die "无法从可信镜像源得到摘要匹配的 $local_ref"
}

pull_images() {
	each_image pull_one
}

new_secret_file() {
	local dest="$1" value
	value=$(openssl rand -hex 24)
	[[ "$value" =~ ^[0-9a-f]{48}$ ]] || die "openssl 没有生成可用密钥"
	printf '%s' "$value" >"$dest"
	chown root:root "$dest"
	# Directory is 0700. 0644 lets the unprivileged container user read the mount.
	chmod 644 "$dest"
	unset value
}

validate_secret_file() {
	local value
	value=$(<"$1")
	[[ "$value" =~ ^[0-9a-f]{48}$ ]] || die "密钥文件格式异常: $(basename "$1")"
	unset value
}

named_volume_exists() {
	local volume
	for volume in erpnext-lowmem-db-data erpnext-lowmem-sites erpnext-lowmem-logs erpnext-lowmem-redis-queue-data; do
		if docker volume inspect "$volume" >/dev/null 2>&1; then
			return 0
		fi
	done
	return 1
}

render_secrets() {
	local names=(db_root_password admin_password redis_cache_password redis_queue_password)
	local name existing=0 missing=0
	mkdir -p "$ROOT/secrets"
	chown root:root "$ROOT/secrets"
	chmod 700 "$ROOT/secrets"
	for name in "${names[@]}"; do
		if [[ -f "$ROOT/secrets/$name" ]]; then
			existing=$((existing + 1))
		else
			missing=$((missing + 1))
		fi
	done
	if [[ "$existing" -gt 0 && "$missing" -gt 0 ]]; then
		die "secrets 目录密钥不完整，拒绝生成或覆盖"
	fi
	if [[ "$existing" -eq 0 ]]; then
		if named_volume_exists; then
			die "数据卷已存在但密钥不存在，拒绝生成新密码"
		fi
		for name in "${names[@]}"; do
			new_secret_file "$ROOT/secrets/$name"
		done
		log "已在 secrets/ 生成 root-only 密钥，内容不会显示"
	else
		for name in "${names[@]}"; do
			validate_secret_file "$ROOT/secrets/$name"
			chown root:root "$ROOT/secrets/$name"
			chmod 644 "$ROOT/secrets/$name"
		done
		log "复用已有密钥文件"
	fi
	python3 "$ROOT/scripts/render_redis_conf.py" \
		"$ROOT/config/redis-cache.conf.template" \
		"$ROOT/secrets/redis-cache.conf" \
		"$ROOT/secrets/redis_cache_password"
	python3 "$ROOT/scripts/render_redis_conf.py" \
		"$ROOT/config/redis-queue.conf.template" \
		"$ROOT/secrets/redis-queue.conf" \
		"$ROOT/secrets/redis_queue_password"
	chown root:root "$ROOT/secrets/redis-cache.conf" "$ROOT/secrets/redis-queue.conf"
	sync
}

assert_rendered_compose_has_no_secrets() {
	local raw redacted
	raw=$(mktemp "$ROOT/state/compose.raw.XXXXXX")
	redacted=$(mktemp "$ROOT/state/compose.redacted.XXXXXX")
	if ! compose config >"$raw"; then
		rm -f "$raw" "$redacted"
		die "docker compose config 失败"
	fi
	python3 "$ROOT/scripts/redact.py" "$ROOT/secrets" <"$raw" >"$redacted"
	if ! cmp -s "$raw" "$redacted"; then
		rm -f "$raw" "$redacted"
		die "渲染后的 Compose 含有密钥，拒绝启动"
	fi
	rm -f "$raw" "$redacted"
	python3 "$ROOT/tests/assert_compose.py" < <(compose --profile task config --format json)
}

wait_healthy() {
	local svc="$1" timeout_s="$2" start now cid status
	start=$(date +%s)
	status=missing
	while true; do
		cid=$(compose ps -q "$svc" || true)
		if [[ -n "$cid" ]]; then
			status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
			if [[ "$status" == "healthy" ]]; then
				log "$svc 健康"
				return 0
			fi
		fi
		now=$(date +%s)
		if ((now - start > timeout_s)); then
			dump_service_logs "$svc"
			die "$svc 在 ${timeout_s}s 内未变为健康（状态: $status）"
		fi
		sleep 5
	done
}

wait_running() {
	local svc="$1" timeout_s="$2" start now cid status
	start=$(date +%s)
	status=missing
	while true; do
		cid=$(compose ps -q "$svc" || true)
		if [[ -n "$cid" ]]; then
			status=$(docker inspect --format '{{.State.Status}}' "$cid")
			if [[ "$status" == "running" ]]; then
				sleep 8
				status=$(docker inspect --format '{{.State.Status}}' "$cid")
				[[ "$status" == "running" ]] || die "$svc 启动后立即退出"
				log "$svc 正在运行"
				return 0
			fi
		fi
		now=$(date +%s)
		if ((now - start > timeout_s)); then
			dump_service_logs "$svc"
			die "$svc 在 ${timeout_s}s 内没有保持运行（状态: $status）"
		fi
		sleep 3
	done
}

dump_service_logs() {
	local svc="$1"
	mkdir -p "$ROOT/state"
	compose logs --no-color --tail 200 "$svc" 2>&1 | python3 "$ROOT/scripts/redact.py" "$ROOT/secrets" >"$ROOT/state/${svc}.log" || true
	chmod 600 "$ROOT/state/${svc}.log" || true
	log "已保存脱敏日志 state/${svc}.log"
}

run_oneshot() {
	local svc="$1"
	log "运行一次性任务 $svc"
	compose up --no-deps --force-recreate --no-color --exit-code-from "$svc" "$svc" 2>&1 |
		python3 "$ROOT/scripts/redact.py" "$ROOT/secrets" |
		tee -a "$ROOT/state/${svc}.log"
	chmod 600 "$ROOT/state/${svc}.log" || true
}

assert_frontend_port() {
	local published line
	published=$(compose port frontend 8080)
	[[ -n "$published" ]] || die "frontend 没有发布端口"
	while IFS= read -r line; do
		[[ "$line" =~ :80$ ]] || die "frontend 端口映射不是宿主 80: $line"
	done <<<"$published"
}

assert_datastores_are_private() {
	local spec name port
	for spec in "db 3306" "redis-cache 6379" "redis-queue 6379" "backend 8000" "websocket 9000"; do
		read -r name port <<<"$spec"
		# Compose 2.40 prints ":0" and exits 0 when a container port is not published.
		published=$(compose port "$name" "$port" 2>/dev/null || true)
		if printf '%s\n' "$published" | grep -E -q ':[1-9][0-9]*$'; then
			die "$name 发布了宿主端口 $port: $published"
		fi
	done
	if docker ps --filter label=com.bdks.stack=erpnext-lowmem --format '{{.Ports}}' | grep -E '(0\.0\.0\.0|\[::\]):8080->' >/dev/null; then
		die "本栈错误地发布了宿主 8080"
	fi
	local host_port
	for host_port in 3306 6379; do
		if ss -H -lnt "sport = :$host_port" | grep -q .; then
			die "宿主端口 $host_port 出现监听，数据库或 Redis 不能公开"
		fi
	done
}

run_preflight() {
	local mem_kb swap_kb avail_kb docker_version compose_version
	log "开始预检"
	if [[ "${ERP_BUNDLE_LAB:-0}" == "1" ]]; then
		log "警告: ERP_BUNDLE_LAB=1，跳过 systemd 单元 zhenbei-escort。生产服务器禁止设置该变量。"
	fi
	[[ "$(uname -m)" == "x86_64" ]] || die "需要 x86_64"
	command -v docker >/dev/null || die "未安装 docker"
	command -v python3 >/dev/null || die "未安装 python3"
	command -v openssl >/dev/null || die "未安装 openssl"
	command -v curl >/dev/null || die "未安装 curl"
	command -v timeout >/dev/null || die "未安装 timeout"
	command -v flock >/dev/null || die "未安装 flock"
	command -v ss >/dev/null || die "未安装 ss（iproute2）"
	command -v sha256sum >/dev/null || die "未安装 sha256sum"
	docker info >/dev/null || die "Docker 守护进程不可用"
	docker compose version >/dev/null || die "未安装 docker compose 插件"
	docker_version=$(docker version --format '{{.Server.Version}}')
	compose_version=$(docker compose version --short)
	version_ge "$docker_version" "24.0.0" || die "Docker $docker_version 过旧"
	version_ge "$compose_version" "2.24.0" || die "Compose $compose_version 过旧"
	log "Docker $docker_version，Compose $compose_version"
	mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
	swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
	avail_kb=$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')
	[[ "$mem_kb" -ge 1700000 ]] || die "内存少于 1.7 GiB，拒绝安装"
	if [[ "$mem_kb" -lt 2600000 && "$swap_kb" -lt 1500000 ]]; then
		die "内存少于 2.5 GiB 且交换空间少于 1.5 GiB，拒绝安装"
	fi
	if [[ "$mem_kb" -lt 2600000 ]]; then
		log "风险: 内存约 $((mem_kb / 1024)) MiB，交换约 $((swap_kb / 1024)) MiB。安装和页面访问会大量使用交换，并发必须保持很低，仍可能因内存不足失败。"
	fi
	[[ "$avail_kb" -ge 10485760 ]] || die "部署目录所在文件系统可用空间少于 10 GiB"
	if ss -H -lnt "sport = :80" | grep -q .; then
		if [[ -z "$(docker ps -q --filter label=com.bdks.stack=erpnext-lowmem --filter publish=80)" ]]; then
			die "宿主 80 端口已被其他进程占用"
		fi
		log "宿主 80 端口当前由本栈占用"
	fi
	if [[ "${ERP_BUNDLE_LAB:-0}" != "1" ]]; then
		command -v systemctl >/dev/null || die "生产机需要 systemd"
		[[ -d /opt/zhenbei-escort ]] || die "缺少 /opt/zhenbei-escort"
	fi
	collect_guard >/dev/null
	local host_port
	for host_port in 3306 6379; do
		if ss -H -lnt "sport = :$host_port" | grep -q .; then
			die "宿主端口 $host_port 已在监听。本部署不接管、不公开数据库或 Redis。"
		fi
	done
	log "预检通过"
}

create_backup() {
	local dest="$1" sql_path base dir suffix
	mkdir -p "$dest"
	chmod 700 "$dest"
	compose exec -T backend bench --site frontend backup --with-files 2>&1 |
		python3 "$ROOT/scripts/redact.py" "$ROOT/secrets" |
		tee -a "$ROOT/state/backup.log" >/dev/null
	sql_path=$(
		compose exec -T backend python3 - <<'PY'
import pathlib
import sys

folder = pathlib.Path("/home/frappe/frappe-bench/sites/frontend/private/backups")
files = sorted(folder.glob("*-database.sql.gz"), key=lambda path: path.stat().st_mtime, reverse=True)
if not files:
    sys.exit(1)
print(files[0])
PY
	)
	sql_path=$(printf '%s' "$sql_path" | tr -d '\r')
	[[ -n "$sql_path" ]] || die "没有找到数据库备份"
	dir=$(dirname "$sql_path")
	base=$(basename "$sql_path")
	base=${base%-database.sql.gz}
	local copied=0
	for suffix in database.sql.gz site_config_backup.json files.tar private-files.tar; do
		if compose exec -T backend test -f "$dir/$base-$suffix"; then
			compose cp "backend:$dir/$base-$suffix" "$dest/$suffix"
			copied=$((copied + 1))
		fi
	done
	[[ "$copied" -ge 1 ]] || die "复制备份失败"
	chown -R root:root "$dest"
	find "$dest" -type f -exec chmod 600 {} +
	python3 - "$dest" <<'PY'
import hashlib
import pathlib
import sys

dest = pathlib.Path(sys.argv[1])
lines = []
for path in sorted(dest.iterdir()):
    if path.name == "MANIFEST.txt":
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    lines.append(digest + "  " + path.name + "  " + str(path.stat().st_size))
manifest = dest / "MANIFEST.txt"
manifest.write_text("\n".join(lines) + "\n", encoding="utf-8")
manifest.chmod(0o600)
PY
	log "备份已写入 $dest"
}

stop_app_tier() {
	compose stop --timeout 40 frontend websocket scheduler worker backend >/dev/null || true
}

start_app_tier() {
	compose up -d --no-deps backend
	wait_healthy backend 240
	compose up -d --no-deps websocket
	wait_healthy websocket 180
	compose up -d --no-deps worker scheduler frontend
	wait_running worker 90
	wait_running scheduler 90
	wait_healthy frontend 180
}

remove_restore_inbox() {
	docker run --rm --user root --entrypoint bash --pull never \
		-v erpnext-lowmem-sites:/sites \
		frappe/erpnext:v16.54.0 \
		-c 'rm -rf /sites/frontend/private/restore-inbox' || true
}
