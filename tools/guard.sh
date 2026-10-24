#!/usr/bin/env bash
#
# tools/guard.sh — 静态护栏（成本极低，先于一切动态测试运行）
#
# 拦的是"编译器不会报错、但架构已经歪了"的那类改动：
#   1. 包依赖方向   —— engine 不该 import app，lib 不该 import 任何本工程包。
#                      拆包时（ADR 0001）最容易踩的坑，一踩就是循环依赖。
#   2. 进程退出点   —— 只有 main.odin 可以 os.exit；各命令必须把退出码
#                      return 给 app.run_main，否则那条路径就没法在单测里断言。
#   3. panic 残留   —— CLI 工具对用户输入不该 panic（应报错 + 退出码 2），
#                      测试代码里的 panic 不算。
#   4. odin check   —— 全包类型检查（比 build 快，且不产物）。
#
# 用法：./tools/guard.sh     退出码 0 全过 / 1 有违规
#
set -uo pipefail

cd "$(dirname "$0")/.."

FAIL=0
SEC_FAIL=0

fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; SEC_FAIL=$((SEC_FAIL + 1)); }
# 小节收尾：本节无违规才打 ok（否则只打分隔，不谎报通过）
close_section() {
  if [[ $SEC_FAIL -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  --    %s（%d 项违规）\n' "$1" "$SEC_FAIL"
  fi
  SEC_FAIL=0
}

# 包 → 允许依赖的本工程包（白名单；未列出的包按"不能依赖任何本工程包"处理）
allowed_for() {
  case "$1" in
    app)    echo "lib search engine" ;;
    engine) echo "lib search" ;;
    search) echo "lib" ;;
    lib)    echo "" ;;
    *)      echo "" ;;
  esac
}

PKGS=(lib search engine app)

echo "==== 1/4 包依赖方向 ===="
for dir in "${PKGS[@]}"; do
  allowed=$(allowed_for "$dir")
  for f in "$dir"/*.odin; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == *_test.odin ]] && continue
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      if [[ " $allowed " != *" $dep "* ]]; then
        fail "${f} 依赖 odd:${dep}（${dir} 只允许：${allowed:-不依赖任何本工程包}）"
      fi
    done < <(grep -o 'import "odd:[a-z_]*"' "$f" 2>/dev/null | sed 's/.*odd://; s/"$//')
  done
done
# main 包只允许 app
for f in ./*.odin; do
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    [[ "$dep" == "app" ]] || fail "${f} 依赖 odd:${dep}（main 只允许 odd:app）"
  done < <(grep -o 'import "odd:[a-z_]*"' "$f" 2>/dev/null | sed 's/.*odd://; s/"$//')
done
close_section "包依赖方向（lib ← search ← engine ← app ← main）"

echo "==== 2/4 进程退出点 ===="
for f in app/*.odin engine/*.odin lib/*.odin search/*.odin; do
  [[ -e "$f" ]] || continue
  [[ "$(basename "$f")" == *_test.odin ]] && continue
  if grep -q 'os\.exit\b' "$f" 2>/dev/null; then
    fail "${f} 调用了 os.exit —— 退出码应 return 给 app.run_main，只有 main.odin 能 os.exit"
  fi
done
close_section "os.exit 只出现在 main.odin"

echo "==== 3/4 panic / 未实现标记 ===="
for f in app/*.odin engine/*.odin lib/*.odin search/*.odin main.odin; do
  [[ -e "$f" ]] || continue
  [[ "$(basename "$f")" == *_test.odin ]] && continue
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    fail "${f}: ${line}"
  done < <(grep -n 'panic(\|unimplemented' "$f" 2>/dev/null)
done
close_section "无 panic / unimplemented"

echo "==== 4/4 odin check（全包类型检查）===="
if [[ -x /usr/bin/clang ]]; then
  export ODIN_CC="${ODIN_CC:-/usr/bin/clang}"
fi
check_pkgs=("." "./lib" "./search" "./engine" "./app")
check_failed=0
for pkg in "${check_pkgs[@]}"; do
  if out=$(odin check "$pkg" -collection:odd=. -no-entry-point 2>&1); then
    :
  else
    printf '%s\n' "$out" | sed 's/^/    /'
    fail "odin check ${pkg}"
    check_failed=1
  fi
done
[[ $check_failed -eq 0 ]] && close_section "odin check 全部通过"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "静态护栏：全部通过"
  exit 0
fi
echo "静态护栏：有违规项（见上）"
exit 1
