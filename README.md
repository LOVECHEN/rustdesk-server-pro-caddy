# rustdesk-server-pro-caddy

官方 **RustDesk Server Pro 原版二进制** + 内嵌 **Caddy**（HTTPS 自动证书反代 Web 控制台）+ **多模式启动**，组装在 `scratch` 单层最小底座上（约 115MB，官方 s6 版为 ~1.3GB）。

- 一个镜像统一「经典单进程版」与「s6 多进程版」——由容器 `command` 决定跑哪些程序、是否上 s6。
- 二进制取自官方 `rustdesk/rustdesk-server-pro-s6`（含全 4 架构），**本镜像不改动二进制**。
- 底座是极简 [`lovechen/tinysys`](https://hub.docker.com/r/lovechen/tinysys)（glibc + openssl + s6 + busybox·sh）。

镜像：`lovechen/rustdesk-server-pro-caddy` · 架构：`amd64` / `arm64` / `armv7`

---

## 快速开始

```bash
docker compose up -d
# 浏览器打开  https://<你的IP或域名>:21120   → Caddy 反代到 Web 控制台
# 默认账号 admin / test1234（首次登录请改）
```

或纯 `docker run`（一体机，自动内网/公网/域名证书决策）：

```bash
docker run -d --name rustdesk --restart unless-stopped \
  -v "$PWD/data:/data" \
  -p 21114:21114 -p 21115:21115 -p 21116:21116 -p 21116:21116/udp \
  -p 21117:21117 -p 21120:21120 \
  lovechen/rustdesk-server-pro-caddy:latest all
```

---

## 启动模式（由 `command` 决定）

| `command` | 跑什么 | 监管 | 用途 |
|---|---|---|---|
| `all`（默认） | hbbs + hbbr + caddy | s6，互相自愈 | 一体机（含 HTTPS 反代） |
| `hbbs` | 仅信令 | **直接 exec，无 s6/无常驻 shell** | 经典单进程信令 |
| `hbbr` | 仅中继 | **直接 exec，无 s6/无常驻 shell** | 分体部署中继 |
| `hbbs hbbr` | 信令 + 中继 | s6 | 无 HTTPS 反代 |
| `hbbs caddy` | 信令 + Caddy | s6 | 只跑信令 + 给控制台套 HTTPS |

规则：**单程序**直接 `exec`（PID1 就是它本身，不起 s6、不留常驻 shell）；**多程序**才用 s6 监管。`caddy` 不能独立启动，必须与 `hbbs` 同启（它反代 hbbs 的 `:21114`）。非受管命令（如 `rustdesk-utils genkeypair`）原样透传。

`examples/` 下有每种模式的 compose 示例。

---

## Caddy 证书策略（内嵌，监听 `:21120` → 反代控制台 `:21114`）

按优先级**自动决策**：

1. **有域名**（`CADDY_DOMAIN=rd.example.com`）→ 域名 ACME（Let's Encrypt）真证书（需 `80/443` 可达校验）。
2. **无域名、探到公网 IP**（含 Oracle/AWS 这类 NAT 公网）→ 公网 IP ACME 真证书（LE 现支持 IP 证书）。
3. **纯内网**（无公网 IP）→ 内网 IP 自签（内部 CA）。

ACME 签不下来一律**回落内部自签兜底**，保证 `:21120` 始终能用。证书存 `/data/caddy`。

手动覆盖：`CADDY_ACME=0` 强制只自签；`CADDY_NOPROBE=1` 关闭对外公网 IP 探测。

---

## 常用环境变量（全部可选）

| 变量 | 说明 |
|---|---|
| `CADDY_DOMAIN` | 反代证书用的域名；不填=自动内网/公网 IP 决策 |
| `CADDY_ACME` | `0`=强制只自签 |
| `CADDY_NOPROBE` | `1`=关闭对外公网 IP 探测 |
| `KEY_PUB` / `KEY_PRIV` | 固定 ed25519 公私钥（不给则首启自动生成到 `/data/id_ed25519*`；分体部署两端须一致） |
| `RELAY` | 中继服务器地址，逗号分隔 |
| `ALWAYS_USE_RELAY` | `Y`=禁直连、强制走中继 |
| `ENCRYPTED_ONLY` | `1`=只收加密连接 |
| `RUST_LOG` | `error`/`warn`/`info`/`debug`/`trace` |

---

## 端口

| 端口 | 用途 |
|---|---|
| 21114 | Web 控制台（Pro） |
| 21115 | NAT type test |
| 21116 (tcp+udp) | 打洞/连接 · ID 注册/心跳 |
| 21117 | 中继（hbbr） |
| 21118 / 21119 | Web client（hbbs / hbbr） |
| 21120 | 内嵌 Caddy HTTPS 反代 |

---

## 构建 / CI

两个 workflow 都做了**版本解析 + digest 溯源 + 幂等**：

- **`build-image`**（`.github/workflows/image.yml`）：多架构构建并推送到 Docker Hub。需在仓库 Secrets 配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`。传 `latest` 会先解析成具体版本(比对官方 index digest)，镜像同时打 `:latest` 和 `:<具体版本>`，并带 `rustdesk.source.digest` label 溯源；`:<具体版本>` 已存在则跳过（`force` 可覆盖）。
- **`extract-official-bins`**（`.github/workflows/extract.yml`）：从官方镜像提取各架构**原版** hbbs/hbbr/rustdesk-utils，发到 GitHub Release `bins-<具体版本>`。Release 里详记 **index digest + 各架构 image digest + 每个二进制 sha256**（见 `MANIFEST.txt`）；若已有该版本 Release 且 index digest 一致则跳过重抠。

**版本解析**：`latest` 是多架构 manifest list，其 index digest 与某个数字 tag 相同即代表二者整包一致——workflow 据此把 `latest` 落到具体版本(如 `1.8.5`)，产物一律用具体版本、不留会被覆盖的移动靶。

本地提取二进制（`latest` 同样会解析成具体版本）：

```bash
./scripts/pull-official-bins.sh -v latest -o official-bins
# 只解析不抠： ./scripts/pull-official-bins.sh -v latest --resolve-only   # 打印「<版本> <index-digest>」
```

（crane 跑在 Docker 里，本机不装任何工具链。CI 里传 `DOCKER_CFG=$HOME/.docker` 让 crane 用登录态、避免匿名限流。）

本地构建镜像：

```bash
docker buildx build --platform linux/amd64 -t rustdesk-server-pro-caddy .
# 指定官方版本： --build-arg RUSTDESK_VER=1.8.5
```
