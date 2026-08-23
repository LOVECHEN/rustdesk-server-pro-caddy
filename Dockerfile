# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# rustdesk-server-pro-caddy —— 官方 RustDesk Server Pro 原版二进制 + 内嵌 Caddy 反代
#                              + 多模式启动，组装在 scratch 单层最小底座上（~115MB）。
#
# 一个镜像统一「经典版」与「s6 版」：由容器 command 决定跑哪些程序、是否上 s6：
#   · command=hbbs / hbbr        → 直接 exec，PID1 就是它本身，【无 s6、无常驻 shell】（= 经典单进程版）
#   · command=all（默认）        → s6 监管 hbbs+hbbr+caddy（= s6 多进程版）
#   · command=hbbs hbbr / hbbs caddy … 任意组合；caddy 不能独立、须随 hbbs
#
# 二进制：官方 rustdesk/rustdesk-server-pro-s6:${RUSTDESK_VER} 的【原版】hbbs/hbbr/rustdesk-utils
#         （含全 4 架构；本镜像不改动二进制）。
# 底座：  lovechen/tinysys（glibc+openssl+zstd+ca+loader+s6+busybox·sh 的极简料场），最终 FROM scratch 单层。
# Caddy： 官方 caddy 静态二进制，HTTPS :21120 反代 hbbs Web 控制台 :21114，证书策略见 caddy-run。
# ─────────────────────────────────────────────────────────────────────────────
ARG BASE=lovechen/tinysys:scratch-glibc-openssl-s6
ARG RUSTDESK_VER=latest

# 静态 musl busybox（自包含，scratch 上也能跑）：s6 的 sh + coreutils
FROM busybox:musl AS bb
RUN mkdir -p /bbin && cp /bin/busybox /bbin/busybox \
 && for a in $(/bbin/busybox --list); do ln -sf busybox /bbin/$a; done

# 官方原版 hbbs/hbbr/rustdesk-utils + 官方 s6 服务树
FROM rustdesk/rustdesk-server-pro-s6:${RUSTDESK_VER} AS pro

# Caddy 静态二进制
FROM caddy:2-alpine AS caddy

# 组装：以 lovechen/tinysys 料场，挑子树进 /rootfs
FROM ${BASE} AS assemble
ARG TARGETARCH
ARG TARGETVARIANT
COPY --from=pro /etc/s6-overlay/s6-rc.d /etc/s6-overlay/s6-rc.d
COPY --from=pro /usr/bin/hbbs /usr/bin/hbbr /usr/bin/rustdesk-utils /usr/bin/
COPY --from=bb  /bbin /bbin
RUN set -eux; \
    case "$TARGETARCH/$TARGETVARIANT" in \
      amd64/*) T=x86_64-linux-gnu ;; \
      arm64/*) T=aarch64-linux-gnu ;; \
      arm/v7)  T=arm-linux-gnueabihf ;; \
      *) echo "unsupported $TARGETARCH/$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    mkdir -p /rootfs; cd /; \
    cp -a --parents "usr/lib/$T" /rootfs/; \
    for l in lib/ld-linux-*.so.* lib64/ld-linux-*.so.*; do [ -e "$l" ] && cp -a --parents "$l" /rootfs/ || true; done; \
    cp -a --parents etc/ld.so.cache etc/ld.so.conf etc/nsswitch.conf /rootfs/ 2>/dev/null || true; \
    [ -d etc/ld.so.conf.d ] && cp -a --parents etc/ld.so.conf.d /rootfs/ || true; \
    cp -a --parents etc/ssl /rootfs/; \
    [ -e usr/lib/ssl ] && cp -a --parents usr/lib/ssl /rootfs/ || true; \
    cp -a --parents init package command etc/s6-overlay /rootfs/; \
    cp -a --parents usr/bin/hbbs usr/bin/hbbr usr/bin/rustdesk-utils /rootfs/; \
    mkdir -p /rootfs/bin; cp -a /bbin/. /rootfs/bin/; \
    printf 'root:x:0:0:root:/root:/bin/sh\n' > /rootfs/etc/passwd; \
    printf 'root:x:0:\n' > /rootfs/etc/group; \
    mkdir -p /rootfs/tmp /rootfs/run /rootfs/var /rootfs/data /rootfs/root; \
    ln -s /run /rootfs/var/run; chmod 1777 /rootfs/tmp; \
    du -sh /rootfs

# ── Caddy 反代服务（s6 longrun）：HTTPS :21120 → hbbs :21114（Web 控制台）──
COPY --from=caddy /usr/bin/caddy /rootfs/usr/bin/caddy
COPY --chmod=755 caddy-run /rootfs/etc/s6-overlay/s6-rc.d/caddy/run
RUN set -eux; S=/rootfs/etc/s6-overlay/s6-rc.d; \
    mkdir -p "$S/caddy/dependencies.d"; \
    echo longrun > "$S/caddy/type"; \
    : > "$S/caddy/dependencies.d/hbbs"; \
    : > "$S/user/contents.d/caddy"

# ── 多模式 entrypoint：command 选 hbbs/hbbr/caddy/all；单程序直 exec 无 s6，多程序上 s6 ──
COPY --chmod=755 entry /rootfs/entry

# ── Web 控制台静态资源(hbbs 从磁盘服务 /static → /usr/share/rustdesk-server/static)──
COPY --from=pro /usr/share/rustdesk-server /rootfs/usr/share/rustdesk-server

FROM scratch
LABEL org.opencontainers.image.authors="LOVE" \
      maintainer="LOVE" \
      org.opencontainers.image.title="rustdesk-server-pro-caddy" \
      org.opencontainers.image.description="RustDesk Server Pro (原版二进制) + 内嵌 Caddy 反代 + 多模式启动, scratch 单层" \
      org.opencontainers.image.source="https://github.com/LOVECHEN/rustdesk-server-pro-caddy"
COPY --from=assemble /rootfs /
ENV PATH=/command:/usr/bin:/bin \
    S6_CMD_WAIT_FOR_SERVICES_MAXTIME=0 S6_KEEP_ENV=1 \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
WORKDIR /data
VOLUME /data
EXPOSE 21114 21115 21116 21116/udp 21117 21118 21119 21120
# command 决定跑哪些程序：hbbs / hbbr / caddy / all(默认)。
#   单程序 → 直接 exec(无 s6/无常驻 shell)；多程序 → s6 监管。caddy 不能独立、须随 hbbs。
ENTRYPOINT ["/entry"]
CMD ["all"]
