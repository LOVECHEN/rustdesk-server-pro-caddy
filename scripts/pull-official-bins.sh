#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pull-official-bins.sh —— 从官方镜像按【各平台】抠出原版 hbbs/hbbr/rustdesk-utils
#
# 版本解析（关键）：
#   传 latest 时，先取 latest 的 index digest，再和各数字 tag(X.Y.Z) 的 digest 逐一比对，
#   解析出 latest 实际对应的【具体版本】(如 1.8.5)。产物/Release 一律用具体版本，不留移动靶。
#
# 溯源（关键）：记录官方 index digest + 各架构 image digest + 每个二进制 sha256，全部写进 MANIFEST。
#
# 用途：
#   ① 各架构原版二进制来源（锁具体版本、带 digest 溯源），供离线/分体部署
#   ② 发布到 GitHub Release（bins-<具体版本>，附完整 digest 清单）
#
# 全程 crane 跑在 Docker 里（本机零污染）；tar/shasum 用系统自带。
#
# 用法：
#   ./pull-official-bins.sh [-v 版本] [-i 镜像] [-o 输出目录] [-a "架构列表"] [--resolve-only]
#     -v  版本 tag，默认 latest（latest 会被解析成具体数字版本）
#     -i  源镜像，默认 rustdesk/rustdesk-server-pro-s6
#     -o  输出目录，默认 ./official-bins
#     -a  架构列表(空格分隔)，默认 "amd64 arm64 arm/v7"
#     --resolve-only  只解析并打印「<具体版本> <index-digest>」，不抠二进制
#
# 产物：
#   <out>/<具体版本>/linux-<arch>/{hbbs,hbbr,rustdesk-utils}
#   <out>/<具体版本>/MANIFEST.txt      # 版本 + index digest + 各架构 digest + 每文件 sha256
#   <out>/<具体版本>/INDEX_DIGEST      # 仅 index digest 一行（供 CI 幂等比对）
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION=latest
IMAGE=rustdesk/rustdesk-server-pro-s6
OUT=./official-bins
ARCHES="amd64 arm64 arm/v7"
RESOLVE_ONLY=0
CRANE_IMG="${CRANE_IMG:-gcr.io/go-containerregistry/crane:latest}"
BINS="hbbs hbbr rustdesk-utils"

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERSION=$2; shift 2 ;;
    -i) IMAGE=$2; shift 2 ;;
    -o) OUT=$2; shift 2 ;;
    -a) ARCHES=$2; shift 2 ;;
    --resolve-only) RESOLVE_ONLY=1; shift ;;
    -h) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "未知参数 '$1'，-h 看用法" >&2; exit 64 ;;
  esac
done

# DOCKER_CFG=<目录> 时把该 docker config 挂进 crane 容器(CI 里 docker login 后传它 → 认证拉取、躲匿名限流)
CFG_MOUNT=""
[ -n "${DOCKER_CFG:-}" ] && [ -f "${DOCKER_CFG}/config.json" ] && CFG_MOUNT="-v ${DOCKER_CFG}:/root/.docker:ro"
crane() { docker run --rm $CFG_MOUNT "$CRANE_IMG" "$@"; }
log() { echo "$@" >&2; }

# 预拉 crane 镜像（首次），避免拉取日志混进要被解析的 stdout
docker image inspect "$CRANE_IMG" >/dev/null 2>&1 || { log ">> 拉取 crane 镜像…"; docker pull -q "$CRANE_IMG" >/dev/null; }

# ── 版本解析：latest → 具体数字版本(比对 index digest) ───────────────────────
resolve() {
  local want="$1" idx t d
  idx=$(crane digest "${IMAGE}:${want}" 2>/dev/null || true)
  [ -z "$idx" ] && { log "✗ 取不到 ${IMAGE}:${want} 的 digest"; exit 1; }
  if [ "$want" != latest ]; then
    # 已是具体版本：直接用
    RESOLVED_VER="$want"; INDEX_DIGEST="$idx"; return
  fi
  # latest：找 digest 与之相同的数字 tag(X.Y.Z)，从高到低
  log ">> 解析 latest（index digest=$idx）…"
  for t in $(crane ls "$IMAGE" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vr); do
    d=$(crane digest "${IMAGE}:${t}" 2>/dev/null || true)
    if [ "$d" = "$idx" ]; then
      RESOLVED_VER="$t"; INDEX_DIGEST="$idx"
      log ">> latest = ${t}"
      return
    fi
  done
  log "✗ latest 未匹配到任何 X.Y.Z 数字 tag（官方可能只发了 latest）"; exit 1
}

resolve "$VERSION"

if [ "$RESOLVE_ONLY" = 1 ]; then
  echo "${RESOLVED_VER} ${INDEX_DIGEST}"
  exit 0
fi

DEST="${OUT}/${RESOLVED_VER}"
MAN="${DEST}/MANIFEST.txt"
mkdir -p "$DEST"
echo "$INDEX_DIGEST" > "${DEST}/INDEX_DIGEST"

log ">> 源镜像: ${IMAGE}:${RESOLVED_VER}"
log ">> index digest: ${INDEX_DIGEST}"
log ">> 架构: ${ARCHES}   输出: ${DEST}"

{
  echo "# RustDesk 官方原版二进制提取清单"
  echo "# 源镜像:       ${IMAGE}:${RESOLVED_VER}"
  [ "$VERSION" = latest ] && echo "# (提取时 latest = ${RESOLVED_VER})"
  echo "# index digest: ${INDEX_DIGEST}"
  echo "# 提取方式:     crane export + tar 抠取(本机零污染)"
  echo
} > "$MAN"

arch_dir() { echo "linux-$(echo "$1" | tr -d '/')"; }   # amd64→linux-amd64  arm/v7→linux-armv7

for A in $ARCHES; do
  PLAT="linux/${A}"
  AD=$(arch_dir "$A")
  D="${DEST}/${AD}"
  mkdir -p "$D"
  log ""
  log "==== ${PLAT} → ${AD} ===="

  DIGEST=$(crane digest --platform "$PLAT" "${IMAGE}:${RESOLVED_VER}" 2>/dev/null || echo "?")
  log "  image digest: ${DIGEST}"
  echo "## ${AD}  (platform=${PLAT})" >> "$MAN"
  echo "#   image-digest: ${DIGEST}" >> "$MAN"

  TAR="${D}/.layer.tar"
  crane export --platform "$PLAT" "${IMAGE}:${RESOLVED_VER}" - > "$TAR" 2>/dev/null
  for B in $BINS; do
    if tar -xOf "$TAR" "usr/bin/${B}" > "${D}/${B}" 2>/dev/null && [ -s "${D}/${B}" ]; then
      chmod +x "${D}/${B}"
      SHA=$(shasum -a 256 "${D}/${B}" | awk '{print $1}')
      SZ=$(wc -c < "${D}/${B}" | tr -d ' ')
      log "  $(printf '%-16s' "$B") ${SHA}  (${SZ} bytes)"
      printf '%s  %s/%s  (%s bytes)\n' "$SHA" "$AD" "$B" "$SZ" >> "$MAN"
    else
      log "  ✗ ${B} 抠取失败"
      echo "# ✗ ${AD}/${B} 缺失" >> "$MAN"
    fi
  done
  echo >> "$MAN"
  rm -f "$TAR"
done

log ""
log ">> 完成。版本=${RESOLVED_VER}  MANIFEST=${MAN}"
cat "$MAN" >&2
