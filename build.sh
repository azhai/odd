#!/usr/bin/env bash
#
# odd 编译脚本
#
# 说明：
#   - 本机 PATH 里的 `clang` 被 Android NDK 的 x86_64 clang 抢先占用，
#     会导致 Odin 链接失败（object file 无法识别）。
#     因此显式指定 ODIN_CC 为系统 Apple clang，并强制 lld 链接器。
#   - 源码按职责拆成子目录包（lib/search/engine/app），见 ADR 0001。
#     Odin 的 import 路径相对源文件所在目录解析，兄弟包之间必须靠 collection
#     才能互相引用，故统一加 -collection:odd=. （路径相对仓库根）。
#
# 用法：
#   ./build.sh                 # 调试/默认构建 → bin/odd
#   OPT=speed ./build.sh       # 换优化级别（none|minimal|size|speed）
#   OUT=/tmp/odd ./build.sh    # 换输出路径
#
set -euo pipefail

cd "$(dirname "$0")"

OUT="${OUT:-bin/odd}"
COLLECTION="${COLLECTION:-odd=.}"
OPT="${OPT:-size}"

if [[ -x /usr/bin/clang ]]; then
  export ODIN_CC="${ODIN_CC:-/usr/bin/clang}"
fi

mkdir -p "$(dirname "$OUT")"

# 提交号注入 lib.ODD_COMMIT（--version 输出 `odd version <v> (commit: <hash>)`，
# 与 gx 的 Version() 同形）。git 不可用 / 非仓库时退化为 dev。
COMMIT="${ODD_COMMIT:-$(git -C . rev-parse --short HEAD 2>/dev/null || echo dev)}"

echo "ODIN_CC = ${ODIN_CC:-<系统默认>}"
echo "commit  = ${COMMIT}"
echo "==== odin build -o:${OPT} ===="

odin build . \
  -collection:"${COLLECTION}" \
  -o:"${OPT}" \
  -define:ODD_COMMIT="${COMMIT}" \
  -linker:lld \
  -out:"${OUT}"

echo "==== 构建完成: ${OUT} ===="
echo "用法: ${OUT} <命令> [参数...]   (命令: find/list/replace/rename/cut/trans/script)"
