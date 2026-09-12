## Realm 一键转发脚本 (Alpine-only fork)

基于 [wcwq98/realm](https://github.com/wcwq98/realm) 原版脚本裁剪，用于在 Alpine Linux（含 musl 容器）中管理 Realm 转发服务。

## 与原版的差异

**仅保留 Alpine / OpenRC**，其余全部移除：

| 项目 | 原版 | 本 fork |
| --- | --- | --- |
| Debian / Ubuntu (`apt`) | 支持 | 已移除 |
| CentOS / RHEL (`yum`) | 支持 | 已移除 |
| systemd (`systemctl`) | 支持 | 已移除 |
| Alpine / OpenRC | 支持 | 保留 |
| Realm 二进制 | `gnu` / `musl` 自动选择 | 保留（Alpine 上走 `musl`） |
| Web 可视化面板 | 支持 | 已移除 |

**Realm 安装与配置初始化逻辑与原版完全一致，未作任何修改**：

- 路径：`/root/realm/realm`、`/root/.realm/config.toml`、`/etc/init.d/realm`
- `init_env` / `write_config_header`：首次运行创建默认 `[network]` 配置头
- `install_realm`：查询 GitHub API 取最新版本（失败回退 `v2.6.0`）→ 下载 musl 版 tar.gz → 解压 → `rc-update add realm default` → `rc-service realm restart`
- 服务定义：`/etc/init.d/realm`（`supervise-daemon`，`depend() { need net }`）

## 部署方式

### 方式一：容器前台托管（推荐，适配廉价容器）

脚本的服务操作依赖 OpenRC（`rc-service` / `rc-update`）。**OpenRC 只在系统由 `/sbin/init` 引导过之后才工作**，因此在非引导容器中会报错：

```text
 * You are attempting to run an openrc service on a
 * system which openrc did not boot.
```

这是 OpenRC 自身的行为，不是脚本问题。实测结论：

| 容器 PID 1 | 结果 |
| --- | --- |
| `sh` / `bash`（裸 `podman run`） | 安装正常完成，但 `rc-service realm start` 被 OpenRC 拒绝 |
| `/sbin/init` | OpenRC 进入引导流程，但容器内 `hostname` / cgroup 只读，default runlevel 启动失败 |

Alpine 的 `openrc` 包**不包含 `openrc-init`**，只有 `/sbin/openrc`、`/sbin/openrc-run`、`rc-service`、`rc-update`。因此容器里更实际的做法是：**用脚本完成安装与配置生成，由容器前台直接托管 realm 进程**。

先把脚本与数据目录放到宿主机：

```sh
mkdir -p ./realm-data/{bin,cfg}
curl -L https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh -o realm.sh
```

创建入口脚本 `entrypoint.sh`（幂等且支持离线重启，可反复重启）：

```sh
#!/bin/sh
# Alpine 基础镜像没有 bash，而本脚本需要 bash。
# 已有依赖时跳过 apk，离线重启也能工作。
if ! command -v bash >/dev/null 2>&1; then
  apk add --no-cache bash curl >/dev/null 2>&1 || true
fi

# 仅在二进制缺失时下载（数据卷持久化后，重启不再联网）
if [ ! -x /root/realm/realm ]; then
  bash -c 'REALM_TESTING=1 . /realm.sh; install_realm' >/dev/null 2>&1 || true
fi

# 设置转发规则：幂等，重复执行不会重复追加；--no-restart 因为由本脚本 exec 托管
bash /realm.sh --set-forward "${FORWARD:-443:1.2.3.4:8443}" --no-restart || exit 1

exec /root/realm/realm -c /root/.realm/config.toml
```

启动容器（注意 `--init`、`-p` 端口暴露与数据卷持久化）：

```sh
podman run -d --name realm \
  --init \
  -m 128m --restart=unless-stopped \
  -p 1234:1234 \
  -e FORWARD=1234:1.1.1.1:443 \
  -v "$PWD/realm.sh:/realm.sh:ro" \
  -v "$PWD/entrypoint.sh:/entrypoint.sh:ro" \
  -v "$PWD/realm-data/bin:/root/realm" \
  -v "$PWD/realm-data/cfg:/root/.realm" \
  alpine:3.22 /bin/sh /entrypoint.sh
```

转发规则通过 `-e FORWARD=` 传入（格式 `<本机端口>:<远程IP或域名>:<远程端口>`），改规则只需改环境变量并重建容器。多个端口就发多个 `-p` 并改用多条 `--set-forward`（可把 entrypoint 里那行换成：

```sh
bash /realm.sh --set-forward "${FORWARD1}" --set-forward "${FORWARD2}" --no-restart || exit 1
```

部署要点（五处都踩过坑）：

| 要点 | 说明 |
| --- | --- |
| **`--init` 建议加** | realm 作为 PID 1 时**不响应 SIGTERM**（内核不向 PID 1 施加默认信号动作），`podman stop` 会等满超时后发 SIGKILL（exit 137）。加 `--init` 让 `podman-init` 接管 PID 1 后，realm 收到 SIGTERM 干净退出（exit 143），停止/启动更快且不残留半关闭连接 |
| `-p 监听端口:监听端口` | 不暴露端口时，容器内 realm 虽在监听，宿主机访问会 `Connection refused`。每个 `[[endpoints]]` 的 `listen` 端口都需在此发布，TCP/UDP 均要覆盖时加 `/udp` |
| `-v .../bin:/root/realm` 与 `-v .../cfg:/root/.realm` | 挂载二进制与配置目录，避免容器重建后重新下载、规则丢失 |
| 端点补齐由 `--set-forward` 保证幂等 | 无 `[[endpoints]]` 时 realm 报 `missing field 'endpoints'` 退出；重复追加会导致 `failed to bind: Address in use` panic。`--set-forward` 已内置幂等判断（同端口同远程跳过），可安全重复执行 |
| 依赖安装失败不得中断启动 | 若写成 `set -e` + 无条件 `apk add`，**离线重启时容器会直接退出**，即使二进制与配置都已在卷中。必须先判断 `command -v bash`、`-x /root/realm/realm`，并给 `apk add` 加 `\|\| true` |

实测数据（Alpine 3.22，rootless podman 5.4.2，`-m 128m`）：realm 常驻内存约 **2.9 MB**。已验证可用的路径：联网全新安装、离线重启（复用数据卷）、`stop` → `start`；三条路径均转发正常（TLSv1.3 握手成功）。

**已知限制：不要用 `podman restart`。** 该命令在同一次调用中先停后启，而 `-p` 发布的端口此时尚未释放，rootless podman 的 pasta 会绑定失败：

```text
Error: pasta failed with exit code 1:
Failed to bind port 1234 (Address already in use)
```

容器随后停留在 `Exited (143)`，需手动 `podman start realm` 恢复。请改用：

```sh
podman stop realm && podman start realm
```

（未发布端口的容器不受影响，这纯粹是端口发布与 `restart` 的时序冲突。）

`REALM_TESTING=1` 让脚本只加载函数、不进入交互菜单，便于脚本化调用单个函数，安装逻辑本身不变。

### 方式二：Alpine 虚拟机 / 裸机（完整 OpenRC 自启）

在由 `/sbin/init` 正常引导的 Alpine 系统上，交互菜单与 OpenRC 服务管理均可用，开机自启走 `rc-update add realm default`：

```sh
apk add --no-cache bash curl
curl -L https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh -o realm.sh
chmod +x realm.sh
bash ./realm.sh
```

进入菜单选 `1` 安装，再选 `3` 添加转发规则；脚本会自动 `rc-update add realm default`，重启后由 OpenRC 拉起 realm。

## 命令行模式（非交互）

除了交互菜单，脚本支持直接传参设置转发，便于脚本化与容器 entrypoint 使用：

```sh
# 本地 443 -> 1.2.3.4 的 8443，自动启用并重启 realm
./realm.sh --set-forward 443:1.2.3.4:8443

# 一次设置多条
./realm.sh --set-forward 80:example.com:8080 --set-forward 443:1.2.3.4:8443

# 仅写配置，不启用/重启服务（容器前台托管场景）
./realm.sh --set-forward 443:1.2.3.4:8443 --no-restart

# 指定本机监听地址（默认 [::]，双栈兼顾 IPv4）
./realm.sh --set-forward 443:1.2.3.4:8443 --listen-addr 0.0.0.0

# IPv6 远程地址需加方括号
./realm.sh --set-forward 8443:[2001:db8::1]:443
```

| 选项 | 说明 |
| --- | --- |
| `--set-forward <本机端口>:<远程IP或域名>:<远程端口>` | 设置转发规则，可重复指定多条 |
| `--listen-addr <地址>` | 本机监听地址，默认 `[::]` |
| `--no-restart` | 仅写配置，不启用/重启服务 |
| `-h`, `--help` | 显示帮助 |

**行为**：

- 端口不存在 → 新增规则
- 端口已存在、远程地址相同 → 跳过（**幂等**，可反复执行）
- 端口已存在、远程地址不同 → **替换**该条规则
- 默认自动 `rc-update add realm default` 并重启 realm；二进制缺失时先自动安装
- 全部规则先解析校验，**任一无效则整体不落盘**，不会留下残缺配置
- 替换仅删除命中的那一个 `[[endpoints]]` 段，`[network]`、`[log]`、注释与其他端点原样保留

退出码：成功 `0`，参数无效或服务未能运行 `1`。

**无参数运行时行为不变**，仍进入交互菜单。

## 脚本界面

```text
################################################
#        Realm 一键转发脚本 (v3.2.6)         #
################################################
 Realm 状态: 运行中
------------------------------------------------
  1. 安装 / 重置 Realm
  2. 卸载 Realm
------------------------------------------------
  3. 添加转发规则
  4. 添加端口段转发
  5. 删除转发规则
  6. 查看当前配置
------------------------------------------------
  7. 启动服务
  8. 停止服务
  9. 重启服务
------------------------------------------------
  10. 更新脚本
  0. 退出脚本
################################################
```

## 默认 Realm 配置

脚本首次部署时自动创建 `/root/.realm/config.toml`：

```toml
[network]
no_tcp = false
use_udp = true
```

添加转发规则后追加 `[[endpoints]]` 段：

```toml
[[endpoints]]
listen = "[::]:1234"
remote = "0.0.0.0:5678"
```

更多参数（`balance`、`through`、`interface`、`extra_remotes` 等）参见上游：

https://github.com/zhboner/realm

## 官方 Realm 文档

https://github.com/zhboner/realm

## License

MIT（沿用原项目）
