## Realm 转发脚本 (Alpine)

用于 Alpine Linux 上一键部署 [Realm](https://github.com/zhboner/realm) 转发服务，支持容器与裸机。

## 部署：容器

宿主机准备目录并下载脚本：

```sh
mkdir -p ./realm-data/{bin,cfg}
curl -L https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh -o realm.sh
```

创建 `entrypoint.sh`：

```sh
#!/bin/sh
if ! command -v bash >/dev/null 2>&1; then
  apk add --no-cache bash curl >/dev/null 2>&1 || true
fi

if [ ! -x /root/realm/realm ]; then
  bash -c 'REALM_TESTING=1 . /realm.sh; install_realm' >/dev/null 2>&1 || true
fi

bash /realm.sh --set-forward "${FORWARD:-443:1.2.3.4:8443}" --no-restart || exit 1

exec /root/realm/realm -c /root/.realm/config.toml
```

启动容器：

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

规则通过 `-e FORWARD=` 传入，格式 `<本机端口>:<远程IP或域名>:<远程端口>`。

注意事项：

- `-p` 必须发布每个 `listen` 端口，否则宿主机访问报 `Connection refused`；UDP 加 `/udp`
- `--init` 建议加：realm 作 PID 1 时不响应 SIGTERM，`podman stop` 会被 SIGKILL
- 用 `podman stop && podman start`，不要用 `podman restart`（端口未释放会导致 pasta 绑定失败）
- 数据卷持久化后支持离线重启，不会重新下载

## 部署：Alpine 裸机 / 虚拟机

```sh
apk add --no-cache bash curl
curl -L https://raw.githubusercontent.com/zincles/realm-alpine-cli/main/realm.sh -o realm.sh
chmod +x realm.sh
bash ./realm.sh
```

无参数运行时进入交互菜单，选 `1` 安装、选 `3` 添加规则。脚本会自动 `rc-update add realm default`，重启后由 OpenRC 拉起 realm。

## 命令行参数

```sh
./realm.sh --set-forward 443:1.2.3.4:8443                    # 自动启用并重启
./realm.sh --set-forward 80:example.com:8080 --set-forward 443:1.2.3.4:8443
./realm.sh --set-forward 443:1.2.3.4:8443 --no-restart       # 仅写配置
./realm.sh --set-forward 443:1.2.3.4:8443 --listen-addr 0.0.0.0
./realm.sh --set-forward 8443:[2001:db8::1]:443              # IPv6 远程需加方括号
```

| 选项 | 说明 |
| --- | --- |
| `--set-forward <本机端口>:<远程IP或域名>:<远程端口>` | 设置转发，可重复指定 |
| `--listen-addr <地址>` | 监听地址，默认 `[::]` |
| `--no-restart` | 仅写配置，不启用/重启服务 |
| `-h`, `--help` | 显示帮助 |

- 同端口同远程 → 跳过（幂等，可反复执行）；同端口不同远程 → 替换
- 规则先全部校验，任一无效则整体不落盘
- 默认自动 `rc-update add realm default` 并重启 realm，二进制缺失时先自动安装
- 退出码：成功 `0`，失败 `1`

## 配置文件

脚本首次运行创建 `/root/.realm/config.toml`：

```toml
[network]
no_tcp = false
use_udp = true
```

设置规则后追加：

```toml
[[endpoints]]
listen = "[::]:1234"
remote = "1.2.3.4:8443"
```

更多参数（`balance`、`through`、`interface`、`extra_remotes` 等）见 [Realm 官方文档](https://github.com/zhboner/realm)。
