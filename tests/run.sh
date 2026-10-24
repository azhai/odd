#!/usr/bin/env bash
#
# tests/run.sh — 差分矩阵：odd vs gx 逐字节比对
#
# 为什么需要这一层（而不是全靠 odin test）：
#   `odin test` 覆盖函数级行为，但**进程级输出文本**验不了 —— 测试运行器并行
#   跑用例，捕获 stdout 会互相污染。因此命令层行为交给这个"两个进程、一次
#   一条命令、逐字节比对"的外部矩阵。
#
# 比对四个维度（缺一不可）：
#   1. stdout    —— 落盘比对，保留结尾换行（不用 $( ) 捕获，否则尾部换行被吃掉）
#   2. stderr    —— 同上
#   3. 退出码    —— 0 有输出 / 1 无命中 / 2 错误
#   4. 工作树    —— 文件名集合 + 每个文件的内容哈希（只对会落盘的命令有意义）
#
# 归一化（只做这几项，其余逐字比对）：
#   <D>    两侧各自的私有工作目录 → 同一占位符（否则路径前缀天然不同）
#   odd    gx 输出里的二进制名 → odd（程序名必然不同）
#   <VER>  版本号与 commit（`v0.3.2 (commit: bf55d7d)` vs `0.1.0 (commit: ...)`）
#   <PAT>  非法正则的编译错误细节：gx 透出 Go regexp 解析器原文，odd 只回显
#          pattern。**已知偏差**，语义（哪一条报错、退出码 2）仍然严格比对。
#   Tengo  已知偏差：gx 内嵌 Tengo，odd 用自研迷你表达式引擎，usage 文案里
#          不写产品名。把 gx 侧的 "Tengo " 删掉再比，其余字符仍是逐字的。
#
# 用法：
#   ./tests/run.sh                      # 用 ./bin/odd 对 /opt/repos/gx/bin/gx
#   ./tests/run.sh ./bin/odd            # 显式指定 odd 二进制
#   GX=/path/to/gx ./tests/run.sh       # 显式指定参照二进制
#   FILTER=sprintf ./tests/run.sh       # 只跑描述里含该子串的用例
#   VERBOSE=1 ./tests/run.sh            # 打印每条用例的完整命令
#
# 退出码：全部通过 0，否则 1。找不到 gx 时打印跳过原因并返回 0
#         （odd 可以独立构建/自测，不该因为它缺席就把 CI 判红）。
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 第一个位置参数可以是 odd 二进制
if [[ $# -gt 0 && -n "${1:-}" && "${1:0:1}" != "-" ]]; then
  BIN="$1"
  shift
else
  BIN="${BIN:-$REPO/bin/odd}"
fi
GX="${GX:-$REPO/../gx/bin/gx}"
# 工作目录刻意不含正则元字符（下面的 sed 用它做替换模式）
WORK="${WORK:-/tmp/odd-tests}"
FILTER="${FILTER:-}"
VERBOSE="${VERBOSE:-0}"

if [[ ! -x "$BIN" ]]; then
  echo "找不到 odd 二进制：$BIN（先跑 ./build.sh）" >&2
  exit 1
fi
if [[ ! -x "$GX" ]]; then
  echo "跳过差分矩阵：找不到参照二进制 $GX"
  echo "（odd 可独立使用；设置 GX=/path/to/gx 可启用差分比对）"
  exit 0
fi

BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
GX="$(cd "$(dirname "$GX")" && pwd)/$(basename "$GX")"

PASS=0
FAIL=0
SKIP=0
FAILED=()

# ---------------------------------------------------------------------------
# 断言基础设施
# ---------------------------------------------------------------------------

SECTION=""
FIXTURE=""    # 夹具函数名；空 = 不需要工作目录内容
FIX_MODE=""   # ""（无夹具） | once（两侧各建一次）| each（每条从母版克隆重建）
CASE_MODE=""  # 空 | files（忽略 stdout/stderr，只比工作树）

begin_section() {
  SECTION="$1"
  FIXTURE="${2:-}"
  FIX_MODE="${3:-}"
  CASE_MODE=""
  echo
  echo "==== ${SECTION} ===="

  if [[ -z "$FIXTURE" ]]; then
    # 无夹具的 section（顶层 / cut / trans）也要有干净的工作目录，
    # 否则 run_case 里的 `cd` 会失败并往 stderr 吐噪音。
    rm -rf "$WORK/g" "$WORK/o"
    mkdir -p "$WORK/g" "$WORK/o"
    return
  fi

  case "$FIX_MODE" in
  once)
    # 只读命令的夹具建一次就够。**这不是纯粹的提速**：本机的 touch/SetFile
    # 被沙箱 shim 包装成 broker IPC 调用，重复建树会从秒级拖到分钟级，
    # 偶尔还会永久挂起（list 的 36 条用例曾因此跑了 30 分钟没结束）。
    # 必须两侧各建一次而不是克隆：list 依赖 birthtime，而 birthtime 是
    # 创建时间，无法通过 cp 复制。
    "$FIXTURE" "$WORK/g"
    "$FIXTURE" "$WORK/o"
    ;;
  each)
    # 会落盘的命令（replace -x / rename -x）：每条用例前从母版克隆，
    # 比每次重新 mkdir+printf 少一半进程创建。
    rm -rf "$WORK/master"
    "$FIXTURE" "$WORK/master"
    ;;
  esac
}

# snapshot <dir> <outfile> — 工作树指纹：文件名集合 + 内容哈希。
# 内容哈希用 `-exec ... +` 批量起进程（每条用例要跑两次，逐文件起 shasum
# 在 replace/rename 的 ~60 条用例上会累积成几百次进程创建）；排序后比对，
# 因此 find 的遍历顺序不影响结果。
snapshot() {
  local d=$1 out=$2
  (
    if cd "$d" 2>/dev/null; then
      find . | LC_ALL=C sort
      echo '=== contents ==='
      find . -type f -exec shasum {} + 2>/dev/null | LC_ALL=C sort
    fi
  ) > "$out"
}

# normalize <infile> <outfile> <private_dir> — 见文件头"归一化"一节。
normalize() {
  local gd=$3
  sed \
    -e "s|${gd}|<D>|g" \
    -e 's|^\([A-Za-z]*\) version v\{0,1\}[0-9][^ ]* (commit: [^)]*)$|\1 version <VER>|' \
    -e 's|gx|odd|g' \
    -e 's|Tengo ||g' \
    -e 's|^Error: invalid regex pattern: .*|Error: invalid regex pattern: <PAT>|' \
    -e 's|^.*invalid regex pattern: .*|Error: invalid regex pattern: <PAT>|' \
    "$1" > "$2"
}

# run_case <描述> [命令参数...]
run_case() {
  local desc="$1"
  shift

  if [[ -n "$FILTER" && "$desc" != *"$FILTER"* ]]; then
    return
  fi

  local gd="$WORK/g" od="$WORK/o"
  if [[ "$FIX_MODE" == "each" ]]; then
    rm -rf "$gd" "$od"
    cp -a "$WORK/master" "$gd"
    cp -a "$WORK/master" "$od"
  fi

  [[ "$VERBOSE" == "1" ]] && printf '  $ %s %s\n' "$BIN" "$*"

  local g_code o_code
  ( cd "$gd" && "$GX" "$@" < "${STDIN_FILE:-/dev/null}" ) > "$WORK/g.out" 2> "$WORK/g.err"
  g_code=$?
  ( cd "$od" && "$BIN" "$@" < "${STDIN_FILE:-/dev/null}" ) > "$WORK/o.out" 2> "$WORK/o.err"
  o_code=$?

  # 归一化：本机每个进程都有 shim 开销，所以空文件直接写空，
  # 不为了"统一流程"白起一个 sed。
  normalize "$WORK/g.out" "$WORK/g.norm" "$gd"
  normalize "$WORK/o.out" "$WORK/o.norm" "$od"
  if [[ -s "$WORK/g.err" || -s "$WORK/o.err" ]]; then
    normalize "$WORK/g.err" "$WORK/g.nerr" "$gd"
    normalize "$WORK/o.err" "$WORK/o.nerr" "$od"
  else
    : > "$WORK/g.nerr"
    : > "$WORK/o.nerr"
  fi

  # 工作树只在有夹具时才有意义（顶层 / cut / trans 的目录恒为空）。
  if [[ -n "$FIXTURE" ]]; then
    snapshot "$gd" "$WORK/g.tree"
    snapshot "$od" "$WORK/o.tree"
  else
    : > "$WORK/g.tree"
    : > "$WORK/o.tree"
  fi

  local bad=()
  [[ $g_code -ne $o_code ]] && bad+=("退出码 gx=${g_code} odd=${o_code}")

  if [[ "$CASE_MODE" != "files" ]]; then
    cmp -s "$WORK/g.norm" "$WORK/o.norm" || bad+=("stdout")
    cmp -s "$WORK/g.nerr" "$WORK/o.nerr" || bad+=("stderr")
  fi
  if [[ -n "$FIXTURE" ]]; then
    cmp -s "$WORK/g.tree" "$WORK/o.tree" || bad+=("工作树")
  fi

  if [[ ${#bad[@]} -eq 0 ]]; then
    PASS=$((PASS + 1))
    printf 'PASS %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    FAILED+=("[$SECTION] $desc")
    printf 'FAIL %s  —— %s\n' "$desc" "$(IFS=,; echo "${bad[*]}")"
    for what in "${bad[@]}"; do
      case "$what" in
        stdout)
          printf '  --- stdout 差异（gx 左 / odd 右）\n'
          diff -u "$WORK/g.norm" "$WORK/o.norm" | sed -n '3,20p' | sed 's/^/    /'
          ;;
        stderr)
          printf '  --- stderr 差异（gx 左 / odd 右）\n'
          diff -u "$WORK/g.nerr" "$WORK/o.nerr" | sed -n '3,20p' | sed 's/^/    /'
          ;;
        工作树)
          printf '  --- 工作树差异（gx 左 / odd 右）\n'
          diff -u "$WORK/g.tree" "$WORK/o.tree" | sed -n '3,20p' | sed 's/^/    /'
          ;;
      esac
    done
  fi
  CASE_MODE=""
}

# ---------------------------------------------------------------------------
# 夹具
# ---------------------------------------------------------------------------

# 固定 mtime + birthtime。list 的 -M/--ctime/-s mtime 需要两侧时间戳逐字节一致，
# 否则 gx/odd 各建一棵树会差几秒。SetFile 改 creation date，touch 改 mtime，
# 符号链接自身的 mtime 用 touch -h；birthtime 无法设置 → ctime 用例一律加
# `-t f` 排除链接。**只在 begin_section 里调用一次**（见上面的 shim 说明）。
setmt() { # $1=路径 $2=touch 参数(YYYYMMDDhhmm) $3=SetFile 参数(MM/DD/YYYY hh:mm:ss)
  touch -t "$2" "$1"
  SetFile -d "$3" "$1" 2>/dev/null
}

fixture_find() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d/sub" "$d/.hidden" "$d/skipme" "$d/build"
  printf 'hello world\nhello again\nbye\n' > "$d/a.txt"
  printf 'hello there\n'                   > "$d/b.txt"
  printf 'nothing here\n'                  > "$d/sub/c.txt"
  printf 'hidden hello\n'                  > "$d/.hidden/d.txt"
  printf 'skip hello\n'                    > "$d/skipme/e.txt"
  printf '*.log\nbuild/\n'                 > "$d/.gitignore"
  printf 'log hello\n'                     > "$d/x.log"
  printf 'build hello\n'                   > "$d/build/f.txt"
}

fixture_replace() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d/sub" "$d/.git"
  printf 'hello world\nfoo bar\nFOO baz\nno match here\n' > "$d/a.txt"
  printf 'second foo line\nfoo foo\n'                     > "$d/sub/b.txt"
  printf 'foo=1\n'                                        > "$d/c.log"
  printf 'secret foo\n'                                   > "$d/.hidden.txt"
  printf 'ignored foo\n'                                  > "$d/skip.txt"
  printf 'skip.txt\n'                                     > "$d/.gitignore"
  printf 'foo\x00binary\n'                                > "$d/bin.dat"
}

fixture_rename() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d/sub" "$d/olddir"
  printf 'x\n' > "$d/foo_one.txt"
  printf 'x\n' > "$d/foo_two.txt"
  printf 'x\n' > "$d/plain.txt"
  printf 'x\n' > "$d/sub/foo_three.txt"
  printf 'x\n' > "$d/IMG_001.jpg"
  printf 'x\n' > "$d/colon.tar.gz"
  printf 'x\n' > "$d/a.b.c"
}

fixture_list() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d/sub" "$d/deep/nest"
  printf 'alpha\n' > "$d/a.txt"
  printf 'bravo bravo\n' > "$d/b.log"
  head -c 2048 /dev/zero > "$d/medium.txt"
  head -c 5000 /dev/zero > "$d/big.bin"
  printf 'x\n' > "$d/sub/c.txt"
  printf 'y\n' > "$d/deep/nest/d.txt"
  printf 'z\n' > "$d/.hidden"
  # 三条 size 与 mtime 都相同的记录：用于固定 sort 的并列顺序
  # （gx 在 reverse 时会把并列项再倒过来，这正是容易写错的地方）
  printf 'tieAAA\n' > "$d/tie1.txt"
  printf 'tieBBB\n' > "$d/tie2.txt"
  printf 'tieCCC\n' > "$d/tie3.txt"
  ln -sf a.txt "$d/link_a"
  ln -sf sub "$d/link_sub"
  ln -sf /nope/missing "$d/link_broken"

  setmt "$d/tie1.txt"         201901010000 "01/01/2019 00:00:00"
  setmt "$d/tie2.txt"         201901010000 "01/01/2019 00:00:00"
  setmt "$d/tie3.txt"         201901010000 "01/01/2019 00:00:00"
  setmt "$d/a.txt"            202001010000 "01/01/2020 00:00:00"
  setmt "$d/sub/c.txt"        202002010000 "02/01/2020 00:00:00"
  setmt "$d/b.log"            202103010000 "03/01/2021 00:00:00"
  setmt "$d/medium.txt"       202204010000 "04/01/2022 00:00:00"
  setmt "$d/big.bin"          202305010000 "05/01/2023 00:00:00"
  setmt "$d/.hidden"          202406010000 "06/01/2024 00:00:00"
  setmt "$d/sub"              202407010000 "07/01/2024 00:00:00"
  setmt "$d/deep"             202408010000 "08/01/2024 00:00:00"
  setmt "$d/deep/nest"        202409010000 "09/01/2024 00:00:00"
  setmt "$d/deep/nest/d.txt"  202410010000 "10/01/2024 00:00:00"
  touch -h -t 202411010000 "$d/link_a"
  touch -h -t 202412010000 "$d/link_sub"
  touch -h -t 202501010000 "$d/link_broken"
}

fixture_script() {
  local d=$1
  rm -rf "$d"; mkdir -p "$d"
}

# ---------------------------------------------------------------------------
# 共享输入文件（cut / trans / script 用，两侧共用只读）
# ---------------------------------------------------------------------------

mkdir -p "$WORK" "$WORK/scripts"

printf 'a,b,c\nd,e,f\n'                     > "$WORK/in_csv.txt"
printf 'x\ty\tz\n'                          > "$WORK/in_tab.txt"
printf '  pad me  \n\ttabbed\t\n'           > "$WORK/in_ws.txt"
printf 'héllo wörld\n'                      > "$WORK/in_utf8.txt"
printf 'a\r\nb\r\n'                         > "$WORK/in_crlf.txt"
printf 'no-newline-end'                     > "$WORK/in_nonl.txt"
printf '\n\n'                               > "$WORK/in_blank.txt"
printf 'one\ntwo\nthree\n'                  > "$WORK/in3.txt"
printf 'alpha\nbeta\ngamma delta\n'         > "$WORK/stdin_script.txt"

# script -f 的脚本文件（gx 要求显式 import；顶层必须 __out := 才生效）
cat > "$WORK/scripts/s1.tengo" <<'EOS'
text := import("text")
__out := text.to_upper(line)
EOS
cat > "$WORK/scripts/s2.tengo" <<'EOS'
fmt := import("fmt")
__out := fmt.sprintf("%03d %s", lineno, line)
EOS
cat > "$WORK/scripts/s3.tengo" <<'EOS'
__out := content
EOS

echo "odd = $BIN"
echo "gx  = $GX"
echo "work= $WORK"

# ===========================================================================
# 顶层 / 全局参数
# ===========================================================================
begin_section "顶层（usage / version / 未知命令）"
run_case "无参数"
run_case "--help"           --help
run_case "-h"               -h
run_case "--version"        --version
run_case "-V"               -V
run_case "未知命令"          bogus
run_case "未知全局参数"      --nope

# ===========================================================================
# cut —— 字段提取
# ===========================================================================
begin_section "cut"
run_case "cut -f 2 file"              cut -f 2 -d , "$WORK/in_csv.txt"
run_case "cut -f 1,3 file"            cut -f 1,3 -d , "$WORK/in_csv.txt"
run_case "cut -f 2- file"             cut -f 2- -d , "$WORK/in_csv.txt"
run_case "cut -f -2 file"             cut -f -2 -d , "$WORK/in_csv.txt"
run_case "cut -f 3-5 file"            cut -f 3-5 -d , "$WORK/in_csv.txt"
run_case "cut -f 9 越界"              cut -f 9 -d , "$WORK/in_csv.txt"
run_case "cut -f 1 分隔符不命中"      cut -f 1 -d ';' "$WORK/in_csv.txt"
run_case "cut -s 分隔符不命中"        cut -f 1 -s -d ';' "$WORK/in_csv.txt"
run_case "cut 非法字段"               cut -f x -d , "$WORK/in_csv.txt"
run_case "cut 空字段"                 cut -f '' -d , "$WORK/in_csv.txt"
run_case "cut 只有横线"               cut -f - -d , "$WORK/in_csv.txt"
run_case "cut 高<低"                  cut -f 5-2 -d , "$WORK/in_csv.txt"
run_case "cut 字段 0"                 cut -f 0 -d , "$WORK/in_csv.txt"
run_case "cut 缺 -f"                  cut -d , "$WORK/in_csv.txt"
run_case "cut --output-delimiter"     cut -f 1,2 -d , --output-delimiter ';' "$WORK/in_csv.txt"
run_case "cut 制表符文件"             cut -f 2 "$WORK/in_tab.txt"
run_case "cut CRLF"                   cut -f 1 -d , "$WORK/in_crlf.txt"
run_case "cut 无结尾换行"             cut -f 1 -d , "$WORK/in_nonl.txt"
run_case "cut 空行"                   cut -f 1 -d , "$WORK/in_blank.txt"
run_case "cut -d '\t'"                cut -f 2 -d '\t' "$WORK/in_tab.txt"
run_case "cut 文件不存在"             cut -f 1 -d , "$WORK/definitely-not-here.txt"
run_case "cut --help"                 cut --help

# ===========================================================================
# trans —— 文本变换
# ===========================================================================
begin_section "trans"
run_case "trans upper"          trans upper   "$WORK/in_csv.txt"
run_case "trans lower"          trans lower   "$WORK/in_csv.txt"
run_case "trans trim"           trans trim    "$WORK/in_ws.txt"
run_case "trans squeeze"        trans squeeze "$WORK/in_ws.txt"
run_case "trans reverse"        trans reverse "$WORK/in_csv.txt"
run_case "trans reverse utf8"   trans reverse "$WORK/in_utf8.txt"
run_case "trans upper utf8"     trans upper   "$WORK/in_utf8.txt"
run_case "trans 未知变换"       trans bogus   "$WORK/in_csv.txt"
run_case "trans 文件不存在"     trans upper   "$WORK/definitely-not-here.txt"
run_case "trans squeeze CRLF"   trans squeeze "$WORK/in_crlf.txt"
run_case "trans reverse 空行"   trans reverse "$WORK/in_blank.txt"
run_case "trans trim 无结尾换行" trans trim   "$WORK/in_nonl.txt"
run_case "trans --help"         trans --help

# ===========================================================================
# find —— 模式搜索（只读，夹具建一次）
# ===========================================================================
begin_section "find" fixture_find once
run_case "find hello"                find hello
run_case "find -i HELLO"             find -i HELLO
run_case "find 正则 h.llo"           find "h.llo"
run_case "find -g *.txt"             find -g "*.txt" hello
run_case "find 无匹配"               find zzzz
run_case "find -A（忽略 gitignore）" find -A hello x.log
run_case "find 指定路径"             find hello sub
run_case "find 指定文件"             find hello a.txt
run_case "find --help"               find --help

# ===========================================================================
# replace —— 搜索 + 替换（会落盘 → 每条重建夹具）
# ===========================================================================
begin_section "replace" fixture_replace each

echo '-- 搜索模式（无 -x）'
run_case "search all"          replace foo
run_case "search path"         replace foo .
run_case "search -N"           replace foo -N .
run_case "search --no-color"   replace foo --no-color .
run_case "search -i"           replace -i foo .
run_case "search -F literal"   replace -F "foo" .
run_case "search -g glob"      replace foo -g "*.log" .
run_case "search -A all"       replace foo -A .
CASE_MODE=files run_case "search -j 2"   replace foo -j 2 .
run_case "search 无命中"       replace zzz .
run_case "search 非法正则"     replace "[" .
run_case "search -f pattern"   replace -f foo .

echo '-- 替换模式（干跑）'
run_case "dry foo->bar"        replace foo bar .
run_case "dry 分组"            replace '(f)(oo)' '$2$1' .
run_case "dry -i"              replace -i foo BAR .
run_case "dry -F"              replace -F "foo" "X" .
run_case "dry -N"              replace foo bar -N .
run_case "dry --no-color"      replace foo bar --no-color .
run_case "dry -g"              replace foo bar -g "*.log" .
run_case "dry -A"              replace foo bar -A .
CASE_MODE=files run_case "dry -j 2"      replace foo bar -j 2 .
run_case "dry -j 0 零 worker"  replace foo bar -j 0 .
run_case "dry 空替换串"        replace foo "" .
run_case "dry 无命中"          replace zzz bar .
run_case "dry -r flag"         replace foo -r bar .
run_case "dry 非法正则"        replace "[" bar .

echo '-- 替换模式（落盘 -x）'
run_case "exec foo->bar"       replace foo bar -x .
run_case "exec -i"             replace -i FOO qux -x .
run_case "exec 分组"           replace '(f)(oo)' '$2$1' -x .
run_case "exec 无命中"         replace zzz bar -x .
run_case "exec -g"             replace foo bar -x -g "*.txt" .
CASE_MODE=files run_case "exec -j 2"     replace foo bar -x -j 2 .
CASE_MODE=files run_case "exec -j 0 零 worker" replace foo bar -x -j 0 .
run_case "replace --help"      replace --help

# ===========================================================================
# rename —— 批量改名（会落盘 → 每条重建夹具）
# ===========================================================================
begin_section "rename" fixture_rename each
run_case "dry foo->bar"          rename foo bar
run_case "exec foo->bar"         rename foo bar -x
run_case "dry 前缀"              rename '^foo' 'x_foo'
run_case "exec 前缀"             rename '^foo' 'x_foo' -x
run_case "exec 扩展名"           rename '\.txt$' '.md' -x
run_case "dry 分组"              rename 'foo_(one|two)' 'F_$1'
run_case "exec 分组交换"         rename '(foo)_(one)' '$2_$1' -x
run_case "exec -i"               rename -i 'img' 'photo' -x
run_case "exec -g jpg"           rename 'IMG' 'PIC' -x -g '*.jpg'
run_case "exec -F literal"       rename -F 'tar.gz' 'tgz' -x
run_case "exec -d 含目录"        rename -d 'olddir' 'newdir' -x
run_case "dry 无 -d"             rename 'olddir' 'newdir'
run_case "exec 冲突"             rename 'plain' 'foo_one' -x
run_case "exec 冲突 --force"     rename 'plain' 'foo_one' -x --force
run_case "无匹配"                rename zzz bar
run_case "无匹配 exec"           rename zzz bar -x
run_case "非法正则"              rename '[' 'x'
run_case "exec 单文件"           rename foo Z -x plain.txt
run_case "exec 行首插入"         rename '^' 'P_' -x -g '*.txt'
run_case "exec 空替换串"         rename 'foo' ''
run_case "rename --help"         rename --help

# ===========================================================================
# list —— 目录列举（只读，夹具建一次；时间戳夹具较贵）
# ===========================================================================
begin_section "list" fixture_list once
run_case "默认"                 list
run_case "显式 ."               list .
run_case "子目录"               list sub
run_case "type d"               list -t d
run_case "type f"               list -t f
run_case "type l"               list -t l
run_case "glob txt"             list -g "*.txt"
run_case "glob nested"          list -g "*.log" .
run_case "format name"          list --format name
run_case "format long"          list --format long
run_case "format show"          list --format show
run_case "size >1K"             list -S ">1K"
run_case "size <=1K"            list -S "<=1K"
run_case "size =5000"           list -S "5000"
run_case "mtime 相对"           list -M "<=1d"
run_case "mtime 绝对"           list -M ">=2024-01-01"
run_case "ctime 绝对"           list -t f --ctime ">=2024-01-01"
run_case "sort name"            list -s name
run_case "sort name 反序"       list -s name -r
run_case "sort size"            list -s size
run_case "sort size 反序"       list -s size -r
run_case "sort mtime"           list -s mtime
run_case "sort mtime 反序"      list -s mtime -r
run_case "sort 并列 size"        list -t f -s size
run_case "sort 并列 size 反序"   list -t f -s size -r
run_case "sort 并列 mtime"       list -t f -s mtime
run_case "sort 并列 mtime 反序"  list -t f -s mtime -r
run_case "sort path"            list -s path
run_case "sort ctime"           list -t f -s ctime
run_case "sort ctime 反序"      list -t f -s ctime -r
run_case "max depth 1"          list -L 1
run_case "max depth 2"          list -L 2
run_case "组合过滤"             list -g "*.txt" -S ">=1" -s size -r --format show
run_case "隐藏文件"             list -t f -s name
run_case "空结果"               list sub/deep/nest -M ">=2030-01-01"
run_case "未知参数"             list -Z
run_case "非法 type"            list -t x
run_case "非法 format"          list --format zzz
run_case "非法 sort"            list -s nope
run_case "参数缺值"             list -g
run_case "list --help"          list --help

# ===========================================================================
# script —— 表达式引擎（从 stdin 逐行喂入）
# ===========================================================================
begin_section "script" fixture_script once
STDIN_FILE="$WORK/stdin_script.txt"
run_case "upper"            script -e 'text.to_upper(line)'
run_case "lower"            script -e 'text.to_lower(line)'
run_case "拼接"             script -e 'line + "!"'
run_case "三元 + lineno"    script -e 'lineno % 2 == 0 ? text.to_upper(line) : line'
run_case "lineno"           script -e 'lineno'
run_case "false 过滤"       script -e 'false'
run_case "true 全出"        script -e 'true'
run_case "len"              script -e 'len(line)'
run_case "sprintf"          script -e 'fmt.sprintf("%s:%d", line, lineno)'
run_case "contains"         script -e 'text.contains(line, "a") ? line : "none"'
run_case "has_prefix"       script -e 'text.has_prefix(line, "a")'
run_case "re_match"         script -e 'text.re_match("^a", line) ? "A" : "other"'
run_case "re_replace"       script -e 'text.re_replace("a", line, "A")'
run_case "replace n=-1"     script -e 'text.replace(line, "a", "A", -1)'
run_case "replace n=1"      script -e 'text.replace(line, "a", "A", 1)'
run_case "atoi"             script -e 'text.atoi("42") + 1'
run_case "trim_space"       script -e 'text.trim_space("  x  ")'
run_case "arith"            script -e 'lineno * 2 + 1'
run_case "cmp"              script -e 'lineno >= 2'
run_case "and or"           script -e 'lineno > 1 && len(line) > 3'
run_case "unary not"        script -e '!text.has_prefix(line, "a")'
run_case "float"            script -e '1.5 + 2'
# 以下三条**只比退出码**：两边都失败并给退出码 2，但错误文案格式不同
# （gx 报 Tengo 的 "Parse Error: ..."，odd 报自研引擎的 "syntax error: ..."），
# 属于 README 偏差表已记录的差异。要留的是"双
# 方都判错"这件事本身——odd 早期把未闭合字符串当空串静默通过，正是被
# expr_test 的 test_script_runtime_errors 抓出来的。
CASE_MODE=files run_case "字符串未闭合" script -e '__out := "unterminated'
CASE_MODE=files run_case "括号未闭合"   script -e '__out := (1 + 2'
CASE_MODE=files run_case "未定义变量"   script -e '__out := nope'
run_case "string eq"        script -e 'line == "beta" ? "B" : "x"'
run_case "文件输入"         script -e 'text.to_upper(line)' "$WORK/in3.txt"
run_case "whole 模式"       script --whole -e 'content'
run_case "whole upper"      script --whole -e 'text.to_upper(content)' "$WORK/in3.txt"
run_case "-f 脚本"          script -f "$WORK/scripts/s1.tengo"
run_case "-f sprintf 宽度"  script -f "$WORK/scripts/s2.tengo"
run_case "-f whole"         script --whole -f "$WORK/scripts/s3.tengo"
unset STDIN_FILE

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
echo
echo "=================================================="
printf '合计: PASS=%d FAIL=%d' "$PASS" "$FAIL"
[[ -n "$FILTER" ]] && printf '  （FILTER=%s）' "$FILTER"
echo
if [[ $FAIL -eq 0 ]]; then
  echo "差分矩阵全部通过"
  exit 0
fi
echo
printf '失败用例：\n'
printf '  - %s\n' "${FAILED[@]}"
exit 1
