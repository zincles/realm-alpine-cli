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

## 一键运行

Alpine 默认没有 Bash，先装运行依赖：

```sh
apk add --no-cache bash curl
curl -L https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh -o realm.sh
chmod +x realm.sh
bash ./realm.sh
```

脚本的 `check_dependencies` 会自动补齐 `wget tar sed grep ss ca-certificates openrc` 等缺项。

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

## 容器部署注意

脚本的服务操作依赖 OpenRC（`rc-service` / `rc-update`）。**OpenRC 只在系统由 `/sbin/init` 引导过之后才工作**，因此在非引导容器中：

```text
 * You are attempting to run an openrc service on a
 * system which openrc did not boot.
```

这是 OpenRC 自身的行为，不是脚本问题。实测结论：

| 容器 PID 1 | 结果 |
| --- | --- |
| `sh` / `bash`（裸 `podman run`） | 安装正常完成，但 `rc-service realm start` 被 OpenRC 拒绝 |
| `/sbin/init` | OpenRC 进入引导流程，但容器内 `hostname` / cgroup 只读，default runlevel 启动失败 |

Alpine 的 `openrc` 包**不包含 `openrc-init`**，只有 `/sbin/openrc`、`/sbin/openrc-run`、`rc-service`、`rc-update`。因此廉价容器里更实际的做法是**让 Realm 由容器前台直接托管**，脚本用于安装与生成配置：

```sh
podman run -d --name realm \
  -m 128m --restart=unless-stopped \
  -v ./realm.sh:/realm.sh:ro \
  alpine:3.22 \
  sh -c 'apk add --no-cache bash curl >/dev/null 2>&1
         bash -c "REALM_TESTING=1 . /realm.sh; install_realm" >/dev/null 2>&1
         # realm 要求配置中至少有一条 [[endpoints]]，否则拒绝启动
         # （原版 write_config_header 只写 [network]，此处补齐后才可启动）
         printf "\n[[endpoints]]\nlisten = \"[::]:1234\"\nremote = \"1.1.1.1:443\"\n" >> /root/.realm/config.toml
         exec /root/realm/realm -c /root/.realm/config.toml'
```

**注意**：`write_config_header` 生成的默认配置只有 `[network]` 段，没有 `[[endpoints]]`。在补齐至少一条规则之前，realm 会以 `missing field 'endpoints'` 退出。原版依赖用户进菜单手动添加规则，容器前台托管模式下需自行补齐（如上）。

已实测该模式下转发链路可用（客户端 → 容器 `0.0.0.0:18080` → 上游，TCP 与 UDP 均监听成功）。

`REALM_TESTING=1` 会让脚本只加载函数、不进入交互菜单，便于脚本化调用单个函数。

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
