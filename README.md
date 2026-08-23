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

## 完整 docker-compose.yml（列出全部环境变量）

下面是一份**不省略任何 env**的完整参考。除 `CADDY_DOMAIN` / 密钥 / `RELAY` 需按你的情况改，其余给的都是**默认值**（设不设效果一样），照抄即可跑，按需删改：

```yaml
services:
  rustdesk-server:
    container_name: rustdesk-server
    hostname: rustdesk-server
    image: lovechen/rustdesk-server-pro-caddy:latest
    command: ["all"]                 # all=hbbs+hbbr+caddy；也可 "hbbs" / "hbbr" / "hbbs hbbr" / "hbbs caddy"
    volumes:
      - ./data:/data                 # db、id_ed25519 密钥、caddy 证书(/data/caddy) 都在这
    ports:
      - "21114:21114"                # Web 控制台(Pro)
      - "21115:21115"                # NAT type test
      - "21116:21116"                # TCP 打洞/连接
      - "21116:21116/udp"            # ID 注册/心跳
      - "21117:21117"                # 中继(hbbr)
      - "21118:21118"                # Web client(hbbs)
      - "21119:21119"                # Web client(hbbr)
      - "21120:21120"                # 内嵌 Caddy HTTPS 反代
    environment:
      # 约定：注释掉的 = 可选/按需填(不写走默认)；未注释的 = 默认值，按需改。
      # ── 内嵌 Caddy HTTPS 反代证书 ────────────────────────────────────────
      CADDY_DOMAIN: "rd.example.com"        # 换成你的域名 → 域名 ACME 真证书。设为 "" 或整行注释掉(两者等价)= 不写域名 → 自动 公网IP ACME / 内网自签
      # CADDY_ACME: "0"                     # 强制只自签(不走 ACME)
      # CADDY_NOPROBE: "1"                  # 关闭「对外公网 IP 探测」
      # ── ed25519 密钥：不写=首启自动生成到 /data/id_ed25519*；要固定/分体部署两端一致才填 ──
      # KEY_PUB: "<id_ed25519.pub 内容>"
      # KEY_PRIV: "<id_ed25519 私钥内容>"
      # ── 中继地址(可选)：不写=用本机 hbbr ──
      # RELAY: "1.2.3.4,relay2.example.com"  # 逗号分隔
      # ── 中继 / 日志 / 加密 ──────────────────────────────────────────────
      ALWAYS_USE_RELAY: "N"                 # Y=禁直连、强制走中继
      ENCRYPTED_ONLY: "0"                   # 1=只收加密连接
      RUST_LOG: "info"                      # error / warn / info / debug / trace
      # ── 访问 & 设备控制(Pro；也可在 web 控制台「设置」页配) ──────────────
      ADMIN_NAME: "admin"                   # 默认管理员用户名
      ACCESS_REQUIRE_LOGIN: "Y"             # 访问需登录
      ID_CHANGE_SUPPORT: "Y"                # 允许客户端改 ID
      DISABLE_NEW_DEVICE: "N"               # 禁止新设备注册
      ONLY_ADMIN_ACCESS_UNASSIGNED: "N"     # 只有管理员能访问未分配设备
      ALLOW_NON_ADMIN_SEE_OTHER_GROUP: "N"  # 非管理员可看其他组
      ONLY_ADMIN_ACCESS_LOGS: "N"           # 只有管理员能看日志
      IDP_ALLOW_LOCAL_PASSWORD_LOGIN: "N"   # 仅在配了 OIDC 时才生效：Y=OIDC 之外仍可本地密码登录, N=只走 OIDC。未配 OIDC 时本地登录照常、与此项无关
      SYNC_DEVICE_NAME_WITH_HOSTNAME: "N"   # 设备名同步为 hostname
      DISABLE_READ_ACCESSIBLE: "N"          # 禁止「读取可访问设备」
      NEW_USER_ENFORCE_TFA: "N"             # 新用户强制两步验证
      AUDIT_RETENTION_DAYS: "180"           # 审计日志保留天数
      # ── 安全 / 限流 ─────────────────────────────────────────────────────
      ENABLE_IP_BLOCKER: "N"                # 启用 IP 封禁
      ENABLE_API_ARMOR: "N"                 # API 防护
      MAX_TCP_PER_MIN: "4294967295"         # 每分钟最大 TCP 连接(默认不限)
      MAX_UDP_PER_MIN: "4294967295"         # 每分钟最大 UDP 连接(默认不限)
      IP_DOS_TCP: "0"                       # 单 IP TCP DoS 阈值(0=不限)
      IP_DOS_UDP: "0"                       # 单 IP UDP DoS 阈值(0=不限)
      GEOIP_FILE: "/data/GeoLite2-City.mmdb"  # GeoIP 库路径(就近中继/地理定位；不放该文件则忽略)
      # ── 会话 ────────────────────────────────────────────────────────────
      SESSION_EXPIRE_SINCE_LOGIN: "31536000"  # 登录会话有效期(秒)
    restart: unless-stopped
```

> 只想跑起来：把 `CADDY_DOMAIN` 改成你的域名（或留空走自动决策），其余整段 `environment:` 都可删——全用默认值。分体/单程序部署把 `command` 换成 `hbbs` / `hbbr` 等，见 `examples/`。

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

## 镜像 tag

- `latest` — 滚动，始终指向最新版本。
- `1.8.5`（等具体数字）— 锁定不变，对应官方同版本原版二进制。

架构 `amd64` / `arm64` / `armv7`，`docker pull` 按你的平台自动选。各模式 compose 示例见源码仓库 `examples/`：
https://github.com/LOVECHEN/rustdesk-server-pro-caddy
