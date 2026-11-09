# ERPNext 低内存部署包（v16.54.0）

这个目录是一份可下载的部署包，用来在已有 Ubuntu 服务器上安装一套完整的 Frappe + ERPNext。它使用官方预构建镜像，不在运行时从 GitHub 拉代码，也不改 ERPNext 业务逻辑。

目标机器：Ubuntu 26.04 x86_64，2 vCPU，约 1.9 GiB 内存 + 2 GiB swap，Docker 29.1.3，Compose 2.40.3。宿主上已经有 systemd 服务 `zhenbei-escort`（目录 `/opt/zhenbei-escort`，监听 `127.0.0.1:8080` 并返回 HTTP 200）。本栈只发布宿主 **80 → 容器 8080**。不会绑定 8080、443、3306、6379，也不会改防火墙、安全组或重启机器。

协调者用现有 Windows SSH 把压缩包拷到服务器后执行下面的命令。本包不包含 SSH 凭据。

## 版本与上游

| 组件 | 锁定 | 上游 |
| --- | --- | --- |
| ERPNext 镜像 | `frappe/erpnext:v16.54.0` | <https://github.com/frappe/erpnext/releases/tag/v16.54.0>，镜像 <https://hub.docker.com/r/frappe/erpnext/tags> |
| 索引摘要 | `sha256:33f4d620dcd5858a2dffaa5337e43627b70408a19d94ff396bb0e5023d252dd9` | 与 `images.lock` 一致。也接受 linux/amd64 清单 `sha256:4c80800a38a182fb940acfd0c280ac2bef3358422dcbec75c643cada578aa32b` |
| MariaDB | `mariadb:11.8` | 与上游 `frappe_docker` 的 `overrides/compose.mariadb.yaml`、`pwd.yml` 相同。索引摘要 `sha256:c4124d1afa875e47f2892edf26b482fa54f796e2f342d3717a04ca091a22a9bd` |
| Redis | `redis:8.6-alpine` | 与上游 `overrides/compose.redis.yaml` 相同。索引摘要 `sha256:c343030a535c8c2e430e038f25cca7cfa7497a2b290f12ba2f9003bdfb3086b9` |
| 编排来源 | 官方 frappe_docker 的当前 stable 示例 | <https://github.com/frappe/frappe_docker>，版本变量见本仓库 `example.env` 的 `ERPNEXT_VERSION=v16.54.0` |

官方镜像标签是 ERPNext `v16.54.0`。在本验证机上 `bench list-apps` 显示镜像内的 Frappe 框架是 **16.55.2**，ERPNext 应用是 **16.54.0**。这是镜像自带的组合，不是本包另行安装的版本。

镜像源只使用 `mirrors.txt` 里的两个地址，按顺序尝试：

1. `mirror.ccs.tencentyun.com`
2. `docker.m.daocloud.io`

本地镜像的 RepoDigest 已经匹配锁定摘要时，脚本不再拉取。摘要不符就拒绝覆盖。

## 栈里有什么

- `db`：MariaDB 11.8，只接内部网络 `erpnext-lowmem-data`
- `redis-cache`、`redis-queue`：带密码，只接内部网络。队列 Redis 开 AOF
- `configurator`：写 `common_site_config.json`（数据库主机、两个 Redis URL）
- `create-site`：`bench new-site --install-app erpnext --set-default frontend`，只执行一次
- `backend`：Gunicorn 1 个 worker、2 个线程
- `worker`：一个进程消费 `short,default,long`
- `scheduler`：站点调度器保持启用
- `websocket`：Socket.IO
- `frontend`：容器内 nginx 听 8080，只映射到宿主 80
- 命名卷：`erpnext-lowmem-db-data`、`erpnext-lowmem-sites`、`erpnext-lowmem-logs`、`erpnext-lowmem-redis-queue-data`
- 常驻服务 `restart: unless-stopped`。一次性任务不自动重启

稳态内存上限大约 1.6 GiB（db 448 + redis 64/128 + backend 320 + websocket 160 + worker 256 + scheduler 192 + frontend 48，单位 MiB）。安装站点时 `create-site` 上限是 1536 MiB，再加数据库和 Redis 会超过 1.9 GiB 物理内存，必须靠 2 GiB swap。MariaDB `innodb_buffer_pool_size=128M`，`performance_schema=OFF`。`innodb_snapshot_isolation=OFF` 与上游 frappe_docker 一致，用来避开 MariaDB 11.8 默认快照隔离下的 Frappe 并发错误。

## 2 GiB 机器上的风险

这是低并发配置，不是官方推荐的生产规格。

- 安装 ERPNext 时内存峰值最高。物理内存不够时会大量换页，安装时间会明显长于大内存机器，也可能被 OOM 杀掉。
- 平时只适合一两个人偶尔使用。打印、导入、报表会和唯一的 worker、唯一的 Gunicorn worker 抢内存。
- 数据库和 Redis 的 OOM 分数低于应用进程。内存不够时优先保数据服务，应用进程退出后由 Docker 拉起。
- 没有在真正的 1.9 GiB 机器上跑过安装。下面的「验证记录」写明了哪些是在更大的验证机上测到的。
- 首次安装如果在建站中途失败，站点目录可能留下半成品。脚本不会自动删站。`apply.sh` 再次执行时，若站点目录在但 ERPNext 未装完，会停下来并保留数据卷。确认没有要留的数据后，才能用文末的清除命令删卷重来。
- 没有域名，没有 TLS。访问方式是 `http://<服务器IP>/`。不要把管理员密码发到聊天或工单里。

## 放到服务器上

压缩包展开后是目录 `lowmem-v16.54.0/`。放到 `/opt/erpnext/` 下面，不要放进 `/opt/zhenbei-escort`。脚本拒绝在那个目录里写入。

```bash
sudo mkdir -p /opt/erpnext
sudo tar -xzf erpnext-lowmem-v16.54.0.tar.gz -C /opt/erpnext
cd /opt/erpnext/lowmem-v16.54.0
sudo bash preflight.sh
sudo bash apply.sh
```

`apply.sh` 自己会再跑一遍预检。生产机器不要设置 `ERP_BUNDLE_LAB`。那个变量只用于没有 systemd 的验证机，设置后会跳过 `zhenbei-escort` 单元检查。

预检不通过就直接退出，不创建容器。它要求：

- x86_64，Docker ≥ 24，Compose ≥ 2.24，以及 python3、openssl、curl、ss、flock、sha256sum
- 内存至少约 1.7 GiB；低于约 2.5 GiB 时还必须有至少约 1.5 GiB swap
- 部署目录所在文件系统至少 10 GiB 可用
- `systemctl is-active zhenbei-escort` 为 `active`，`/opt/zhenbei-escort` 存在
- `http://127.0.0.1:8080/` 返回 200，并且能读到监听进程
- 宿主 80 空闲（或已经是本栈），3306 和 6379 没有进程监听

安装过程中会反复比对 8080 的监听进程、HTTP 状态、systemd 单元路径、单元文件哈希和 `/opt/zhenbei-escort` 的 inode。任何一项变化，脚本停止并只回滚本栈（保留数据卷）。它不会 `systemctl` 操作 `zhenbei-escort`，也不会碰那个目录。

成功后日志只打印密码文件路径，不打印密码：

- 管理员：`secrets/admin_password`（用户名 `Administrator`）
- 数据库 root：`secrets/db_root_password`
- Redis：`secrets/redis_cache_password`、`secrets/redis_queue_password`

在服务器上查看管理员密码：

```bash
sudo cat /opt/erpnext/lowmem-v16.54.0/secrets/admin_password
```

密钥由 `openssl rand -hex 24` 在这台机器上生成（48 位十六进制）。`secrets/` 是 root 所有、权限 0700。密钥文件是 0644，这样容器里的非 root 用户能读挂载文件，目录权限仍挡住其他宿主用户。已有密钥不会被覆盖。数据卷还在但密钥丢了时，脚本拒绝生成新密码。

Compose 2.40 会提示 `secrets uid, gid and mode are not supported`。这是 Compose 忽略了文件里的 mode 字段，实际权限以宿主文件为准。看到这行警告可以继续，不要把它当成失败。

## 安装之后

```bash
cd /opt/erpnext/lowmem-v16.54.0
sudo bash healthcheck.sh
sudo bash backup.sh
sudo bash restore.sh /opt/erpnext/lowmem-v16.54.0/backups/<时间戳>
sudo bash rollback.sh
```

`healthcheck.sh` 检查：六个带健康检查的服务、worker 和 scheduler 仍在运行、站点已安装 frappe 与 erpnext、调度器启用、`bench doctor`、`/socket.io/?EIO=4&transport=polling` 返回 Socket.IO 握手、`/login` 与 `/api/method/ping`、以及用密码文件登录 Administrator 并读回当前用户。

`backup.sh` 做 `bench backup --with-files`，把数据库、站点配置和文件复制到 `backups/<UTC时间>/`，目录 0700、文件 0600，并写 `MANIFEST.txt`（sha256）。站点配置备份里有数据库密码，不要打包、不要外传。

`restore.sh <备份目录>` 会先再做一份安全备份，停掉应用层（不停数据库和 Redis），再执行 `bench restore --force`。请求的备份恢复失败时，脚本尝试恢复刚才那份安全备份。两条都失败时，应用层保持停止，数据卷还在，需要人工处理。

`rollback.sh` 只停止并删除本栈容器和本栈网络，保留数据卷，然后再次确认 8080 基线没变。

确认这是一次可以丢弃的安装、且备份已经另存后，才允许删卷：

```bash
sudo ERP_BUNDLE_PURGE_CONFIRM=erpnext-lowmem bash rollback.sh --purge-volumes
```

不带这个环境变量时，`--purge-volumes` 会被拒绝。

## 验证记录

验证机是 Ubuntu 24.04.5、x86_64、Docker 29.1.3、Compose 2.40.3，内存约 15 GiB、没有 swap。它不是目标上的 1.9 GiB 主机，也没有 systemd，因此用 `ERP_BUNDLE_LAB=1` 跳过了 `zhenbei-escort` 单元检查。8080 上有一个独立的 HTTP 200 进程，用来代替那台现有服务做存活比对。

已在这台验证机上做完：

- 静态检查：`bash -n`、shellcheck、py_compile、渲染后的 Compose 契约（端口、内部网络、镜像、重启策略、密钥不出现在明文环境变量里）。在不含密钥的副本上通过。
- 8080 没有 HTTP 200 时，`apply.sh` 在预检阶段退出，没有继续安装。
- 早期一次安装把数据库误判为发布了宿主端口（Compose 2.40 对未发布端口输出 `:0`）。脚本因此中止，并只回滚本栈、保留数据卷，8080 基线不变。该误判已修正后再装成功。
- 腾讯云镜像源在这台验证机上拉取失败。DaoCloud 拉取成功，三个镜像的索引摘要与 `images.lock` 一致，架构为 linux/amd64。目标机若已经按同一摘要打好官方标签，脚本会直接使用本地镜像。
- `apply.sh` 建站成功。站点名 `frontend`。应用为 frappe 16.55.2、erpnext 16.54.0。调度器启用。
- 宿主只发布 `0.0.0.0:80->8080/tcp`。3306、6379、443 没有宿主监听。Redis 不带密码时返回 `NOAUTH`。
- `http://127.0.0.1/`、`/login` 返回 200，`/api/method/ping` 返回 pong，Administrator 登录成功。Socket.IO 轮询握手通过。`bench doctor` 通过。
- 安装结束后空闲内存（cgroup 内）大约：db 210 MiB、backend 139 MiB、websocket 89 MiB、worker 50 MiB、scheduler 43 MiB、两个 Redis 合计约 16 MiB、frontend 5 MiB。这是大内存验证机上的空闲读数，不能当成 2 GiB 机器的余量。
- Gunicorn 为 `--workers=1 --threads=2`。worker 命令行为 `frappe worker --queue short,default,long`。scheduler 为 `frappe schedule`。websocket 为 `socketio.js`。
- 备份、恢复、保留数据卷的隔离回滚、回滚后重新拉起、拒绝无确认删卷，以及重复执行建站，都已在这台验证机上跑完。过程记在同目录 `TESTED.txt`。

没有测到、不能声称已经验证的部分：

- 目标机 Ubuntu 26.04、1.9 GiB 内存和 2 GiB swap 上的安装耗时与是否会被 OOM
- 真实的 systemd 单元 `zhenbei-escort`（验证机没有 systemd）
- 从目标机到 `mirror.ccs.tencentyun.com` 的现场拉取（验证机失败后改走了 DaoCloud；目标机已有镜像时不会再拉）
- HTTPS、域名、多用户并发、打印和长时间后台任务
- `--purge-volumes` 删除数据卷（只验证了拒绝条件和保留数据卷的回滚）
