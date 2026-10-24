#!/usr/bin/env bash
#
# odd 单元测试脚本
#
# 说明：
#   - 与 build.sh 同源问题：PATH 里的 `clang` 可能被 Android NDK 的 x86_64 clang
#     抢先占用，导致 Odin 链接 .o 失败（unknown file type）。因此显式指定
#     ODIN_CC 为系统 Apple clang，并强制 lld 链接器。
#   - **内存追踪保持开启**（不传 -define:ODIN_TEST_TRACK_MEMORY=false）。
#     engine 包会起 worker 线程；Odin 的 Tracking_Allocator 非线程安全，
#     若线程继承调用方分配器会写坏内部 map → 偶发 SIGBUS。
#     本仓库的做法是 worker 入口统一 `context = runtime.default_context()`，
#     追踪就能常开，任何新增的真实泄漏都会立刻以 leak 告警暴露。
#   - **odin test 一次只接受一个路径**：`odin test .` 只跑根目录的 main 包，
#     子包的 *_test.odin 不会被执行。因此逐包跑，用例数是各包之和。
#     包顺序按依赖方向自底向上：lib → search → engine → app → .
#
# 用法：
#   ./test.sh                                    # 全部包
#   ./test.sh ./app                              # 只跑指定包
#   ODIN_TEST_NAMES=engine.test_walk_depth ./test.sh ./engine
#
set -euo pipefail

cd "$(dirname "$0")"

if [[ -x /usr/bin/clang ]]; then
  export ODIN_CC="${ODIN_CC:-/usr/bin/clang}"
fi

COLLECTION="${COLLECTION:-odd=.}"

if [[ $# -gt 0 ]]; then
  PACKAGES=("$@")
else
  PACKAGES=(. ./lib ./search ./engine ./app)
fi

echo "ODIN_CC = ${ODIN_CC:-<系统默认>}"
echo "==== odin test （逐包，内存追踪开启）===="

for pkg in "${PACKAGES[@]}"; do
  echo "---- package: ${pkg} ----"
  odin test "${pkg}" -collection:"${COLLECTION}" -linker:lld
done

echo "==== 单元测试全部完成 ===="
