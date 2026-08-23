#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# pull-official-bins.sh —— 从官方镜像按【各平台】抠出原版 hbbs/hbbr/rustdesk-utils
#
# 用途：
#   ① 各架构原版二进制来源（可锁定版本），供离线部署 / 分体部署
#   ② 发布到 GitHub Release（原版二进制 + MANIFEST 校验）
#
# 全程 crane 跑在 Docker 里（本机零污染，不装任何工具链）；tar/shasum 用系统自带。
#
# 用法：
#   ./pull-official-bins.sh [-v 版本] [-i 镜像] [-o 输出目录] [-a "架构列表"]
#     -v  版本 tag，默认 latest（如 1.1.14 / 1.8.5）
#     -i  源镜像，默认 rustdesk/rustdesk-server-pro-s6（含全 4 架构、/usr/bin 有三件套）
#     -o  输出目录，默认 ./official-bins
#     -a  架构列表(空格分隔)，默认 "amd64 arm64 arm/v7"
#
# 产物布局：
#   <out>/<版本>/linux-<arch>/{hbbs,hbbr,rustdesk-utils}
#   <out>/<版本>/MANIFEST.txt   # 每文件 sha256 + 源镜像 per-arch digest
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

VERSION=latest
IMAGE=rustdesk/rustdesk-server-pro-s6
OUT=./official-bins
ARCHES="amd64 arm64 arm/v7"
CRANE_IMG="${CRANE_IMG:-gcr.io/go-containerregistry/crane:latest}"
BINS="hbbs hbbr rustdesk-utils"

while getopts "v:i:o:a:h" opt; do
  case "$opt" in
    v) VERSION=$OPTARG ;;
    i) IMAGE=$OPTARG ;;
    o) OUT=$OPTARG ;;
    a) ARCHES=$OPTARG ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数，-h 看用法" >&2; exit 64 ;;
  esac
done

REF="${IMAGE}:${VERSION}"
DEST="${OUT}/${VERSION}"
MAN="${DEST}/MANIFEST.txt"
crane() { docker run --rm "$CRANE_IMG" "$@"; }

echo ">> 源镜像: ${REF}"
echo ">> 架构:   ${ARCHES}"
echo ">> 输出:   ${DEST}"
mkdir -p "$DEST"

# 预拉 crane 镜像（首次），避免把 docker 拉取日志混进管道
docker image inspect "$CRANE_IMG" >/dev/null 2>&1 || { echo ">> 拉取 crane 镜像…"; docker pull -q "$CRANE_IMG" >/dev/null; }

{
  echo "# RustDesk 官方原版二进制提取清单"
  echo "# 源镜像: ${REF}"
  echo "# 生成方式: crane export + tar 抠取(本机零污染)"
  echo
} > "$MAN"

arch_dir() { echo "linux-$(echo "$1" | tr -d '/')"; }   # amd64→linux-amd64  arm/v7→linux-armv7

for A in $ARCHES; do
  PLAT="linux/${A}"
  AD=$(arch_dir "$A")
  D="${DEST}/${AD}"
  mkdir -p "$D"
  echo
  echo "==== ${PLAT} → ${AD} ===="

  DIGEST=$(crane digest --platform "$PLAT" "$REF" 2>/dev/null || echo "?")
  echo "  digest: ${DIGEST}"
  echo "## ${AD}  (platform=${PLAT})" >> "$MAN"
  echo "#   image-digest: ${DIGEST}" >> "$MAN"

  # 一次 export，抠三件套（tar 从 stdin 一把流式取三个路径）
  TAR="${D}/.layer.tar"
  crane export --platform "$PLAT" "$REF" - > "$TAR" 2>/dev/null
  for B in $BINS; do
    if tar -xOf "$TAR" "usr/bin/${B}" > "${D}/${B}" 2>/dev/null && [ -s "${D}/${B}" ]; then
      chmod +x "${D}/${B}"
      SHA=$(shasum -a 256 "${D}/${B}" | awk '{print $1}')
      SZ=$(wc -c < "${D}/${B}" | tr -d ' ')
      printf '  %-16s %s  (%s bytes)\n' "$B" "$SHA" "$SZ"
      printf '%s  %s/%s  (%s bytes)\n' "$SHA" "$AD" "$B" "$SZ" >> "$MAN"
    else
      echo "  ✗ ${B} 抠取失败（该镜像可能无此文件）" >&2
      echo "# ✗ ${AD}/${B} 缺失" >> "$MAN"
    fi
  done
  echo >> "$MAN"
  rm -f "$TAR"
done

echo
echo ">> 完成。MANIFEST: ${MAN}"
cat "$MAN"
