#!/usr/bin/env bash
#
# verify.sh — 完整验收（一条命令跑完）
#
# 三层，从廉价到昂贵：
#   0. tools/guard.sh —— 静态护栏（依赖方向 / 退出点 / panic / odin check）
#   1. ./test.sh      —— odin test 逐包单测（含内存泄漏追踪）
#   2. ./tests/run.sh —— 差分矩阵：odd vs gx 逐字节比对（stdout/stderr/退出码/工作树）
#
# 为什么分三层：
#   `odin test` 覆盖函数级行为，但**进程级输出文本**验不了（测试运行器并行
#   跑用例，捕获 stdout 会互相污染）。输出文本交给第 2 层的"两个进程、一次
#   一条命令、逐字节比对"。第 0 层是为了在跑几十秒的矩阵之前就抓住静默的
#   架构走形（比如 engine 反向 import app）。
#
# 用法：
#   ./verify.sh              # 全部
#   ./verify.sh --quick      # 跳过差分矩阵（只跑护栏 + 单测，约 10 秒）
#   FILTER=sprintf ./verify.sh   # 差分矩阵只跑匹配的用例
#
set -uo pipefail

cd "$(dirname "$0")"

QUICK=0
if [[ "${1:-}" == "--quick" ]]; then
  QUICK=1
fi

FAILED_STAGES=()

run_stage() {
  local name="$1"
  shift
  echo
  echo "################ ${name} ################"
  if "$@"; then
    echo "---- ${name}: OK"
  else
    echo "---- ${name}: FAILED"
    FAILED_STAGES+=("$name")
  fi
}

run_stage "静态护栏" ./tools/guard.sh
run_stage "单元测试（逐包）" ./test.sh

if [[ $QUICK -eq 0 ]]; then
  # tests/run.sh 自己会检查 bin/odd 是否存在；先构建保证验的是当前源码。
  ./build.sh > /dev/null || { echo "构建失败"; exit 1; }
  run_stage "差分矩阵（odd vs gx）" ./tests/run.sh
else
  echo
  echo "（--quick：跳过差分矩阵）"
fi

echo
echo "################ 验收汇总 ################"
if [[ ${#FAILED_STAGES[@]} -eq 0 ]]; then
  echo "全部通过"
  exit 0
fi
printf '未通过的阶段：\n'
printf '  - %s\n' "${FAILED_STAGES[@]}"
exit 1
