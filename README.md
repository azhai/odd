# odd

用 [Odin](https://odin-lang.org) 重写的文本处理工具，是 [gx](https://github.com/azhai/gx)（Go 版）的
**逐参数复刻**：七个命令（find / list / replace / rename / cut / trans / script）、
同一套选项语义、同一套退出码、同一套输出文本。

目标是"换一个实现语言，命令行行为不变"——所以验收方式是**差分测试**：
同一批命令分别喂给 `gx` 和 `odd`，逐字节比对 stdout / stderr / 退出码 / 落盘结果。
当前 179 条用例全绿（见 `tests/run.sh`）。

## 特性

- **find** — 文件内容搜索（grep 风格）
  - 正则 / `-F` 字面 / `-i` 忽略大小写，`-g` glob 过滤文件
  - 默认遵循 `.gitignore`，`-A`/`--all` 忽略之
  - 二进制文件检测、`-l` 仅列文件名、`-n`/`-N` 行号开关
  - `-j N` 工作线程（默认 1，`-j 0` = 全部核心），但输出仍按文件序确定性排列
- **list** — 目录列举（ls 风格）
  - `-t f|d|l|a` 类型、`-g` glob、`-S`/`-M`/`--ctime` 大小与时间表达式
  - `-s name|size|mtime|ctime|path` 排序 + `-r` 反序，`-L` 深度
  - `--format path|long|name|show`
- **replace** — 搜索替换，默认干跑
  - `-x` 落盘，`-f`/`-r` 显式指定模式与替换串，支持 `$1` / `${name}` 捕获组
- **rename** — 批量改名（f2 风格）
  - 干跑预览、冲突检测、`--force`、`-d` 含目录、`-g` 过滤
- **cut** — 字段提取（`-f N` / `N-M` / `N-` / `-M` / 逗号混合）
- **trans** — 行变换（`upper` / `lower` / `trim` / `squeeze` / `reverse`）
- **script** — 表达式脚本（sed/awk 风格的轻量替代）

## 构建与验收

```bash
./build.sh          # → bin/odd
./test.sh           # odin test 逐包单测（内存追踪开启）
./tests/run.sh      # 差分矩阵：odd vs gx（179 条）
./verify.sh         # 全部：静态护栏 + 单测 + 差分
./verify.sh --quick # 跳过差分（约 10 秒）
```

单测现状：`lib` 28、`app` 30、`engine` 19、`search` 22（合计 99，全部零泄漏）。
覆盖：`lib` 的 sizeexpr / timeexpr / format / gitignore / base，`app/expr`
（脚本引擎的词法、求值、内建函数、报错路径），`search/regex`（含前导字面量
跳过与"快路径 vs VM"一致性差分），`engine` 的 walker / processor / stream。

差分矩阵默认拿 `../gx/bin/gx` 当参照物，可用 `GX=/path/to/gx` 覆盖；
找不到 gx 时会打印跳过原因并返回 0（odd 可以独立开发）。

## 退出码

沿用 grep 约定，便于写进 `if` 和管道：

| 码 | 含义 |
|----|------|
| 0  | 成功，且有匹配 / 有文件被改名 |
| 1  | 成功，但无匹配 / 无文件被改名 |
| 2  | 错误（参数错误、IO 失败、正则编译失败等） |

## 用法

顶层：

```
odd - A handy text-processing utility (sed/awk style)

Usage: odd <command> [OPTIONS] [ARGS...]

Commands:
  find     Search for patterns in files (like grep)
  list     List files and directories with filters (like ls)
  replace  Search and replace text in files
  rename   Batch rename files
  cut      Extract fields from delimited text (like cut -f)
  trans    Apply text transformations (upper/lower/trim/...)
  script   Run a script over input (sed/awk style)

Global Flags:
  -h, --help       Show help
  -V, --version    Show version
```

### find

```bash
odd find "pattern"                  # 在当前目录搜索
odd find "pattern" src/ test/       # 多个目录
odd find -i -g "*.odin" "TODO"      # 忽略大小写 + 只看 .odin
odd find -F "[test]"                # 字面字符串
odd find -A "debug"                 # 连 .gitignore 忽略的文件一起搜
odd find -l "deprecated" -g "*.py"  # 只列文件名
odd find -j 0 "pattern" ./big       # 全部核心
```

选项：`-A/--all`、`-F/--fixed-strings`、`-g/--glob`、`-i/--ignore-case`、
`-j/--jobs`、`-l/--files-with-matches`、`-n/--line-number`、`-N/--no-line-number`、
`--no-color`、`-h/--help`。

### replace

```bash
odd replace "TODO" "FIXME"            # 干跑预览
odd replace "TODO" "FIXME" -x         # 执行
odd replace -f "TODO" -r "FIXME" -x   # 显式指定
odd replace '(\w+)@(\w+)' '$2:$1' -x  # 捕获组
odd replace -F "[test]" "demo" -x     # 字面字符串
```

选项：在上面的基础上加 `-x/--execute`、`-f/--find`、`-r/--replace`。
替换模板遵循 Go 的 `Expand` 语义：`$1`、`${1}`、`$name`、`${name}`；
`$` 后跟的标识符取最长串，全数字才当组号（禁止前导零，`$01` 视为名字）。

### rename

```bash
odd rename "foo" "bar"              # 预览
odd rename "foo" "bar" -x           # 执行
odd rename '\.txt$' '.md' -x        # 改扩展名
odd rename '(\d+)' 'v$1' -x         # 加前缀
odd rename -i "IMG" "img" -g '*.jpg' -x
odd rename -d 'olddir' 'newdir' -x  # 含目录
```

选项：`-d/--include-dirs`、`-f/--find`、`-r/--replace`、`-F`、`-g`、`-i`、
`-x/--execute`、`--force`、`-h/--help`。

### list

```bash
odd list                            # 递归列举当前目录
odd list -t f -g "*.odin"           # 只看文件 + glob
odd list -S ">1M" -s size -r        # 大于 1M，按大小降序
odd list -M "<=1h"                  # 最近一小时内修改
odd list --ctime ">=2025-01-01"     # 创建时间
odd list --format long -L 2 ./src   # 长格式，深度 2
```

选项：`-a`、`-g/--glob`、`-t/--type`、`-S/--size`、`-M/--mtime`、`--ctime`、
`-s/--sort`、`-r/--reverse`、`--format`、`-L/--max-depth`、`-h/--help`。

大小表达式：`>1M`、`<=100K`、`1024`（裸数字 = 等于）、单位 `B/K/M/G/T`。
时间表达式：相对 `<=1h`、`>7d`（`s m h d w`），绝对 `>=2025-01-01`。

### cut / trans

```bash
printf 'a,b,c\n' | odd cut -f 2 -d ,      # → b
printf 'a,b,c,d\n' | odd cut -f 2-3 -d ,  # → b,c
printf 'a,b,c,d\n' | odd cut -f -2 -d ,   # → a,b
odd cut -f 1,3 -d , --output-delimiter : data.csv

echo "  Hi  " | odd trans trim            # → Hi
echo "a   b" | odd trans squeeze          # → a b
echo "abc" | odd trans reverse            # → cba
```

`-d` 支持转义 `\t` `\n` `\\`；无路径或 `-` 时读 stdin。

### script

```bash
odd script -e 'text.to_upper(line)'              # 行模式
odd script -e 'lineno % 2 == 1 ? line : false'   # 用 false 过滤
odd script -e 'fmt.sprintf("%03d %s", lineno, line)'
odd script --whole -e 'text.count(content, "\n")' # 整文件模式
odd script -f prog.expr                          # 脚本文件
```

- 行模式注入 `line`（string）、`lineno`（int, 1-based）、`filename`（string）；
  `--whole` 注入 `content`（string）、`filename`。
- 结果写在 `__out` 里：string → 输出，`false`/`undefined` → 过滤，其它 → 显示为文本。
- `-e` 会把你写的表达式包成 `__out := (EXPR)`；`-f` 脚本里必须自己给 `__out` 赋值。

**支持的语言子集**（自研递归下降 + 求值器，非完整语言）：

- 运算符：`+ - * / %`、`== != < <= > >=`、`&&` `||`、`!`、一元 `-`、
  三元 `?:`（右结合）、括号、`:=` 赋值、`//` 与 `/* */` 注释
- 字面量：整数、浮点、双引号字符串（含转义）、反引号原样串、`true` / `false` / `undefined`
- 内建函数：`len`、`string`、`int`、`import`（空绑定，让 gx 风格脚本原样跑通）
- `text.`：`to_upper` `to_lower` `trim_space` `trim` `trim_prefix` `trim_suffix`
  `contains` `has_prefix` `has_suffix` `index` `repeat` `replace(s,old,new,n)`
  `atoi` `itoa` `re_match` `re_replace`
- `fmt.`：`sprintf`，支持完整的 `%[flags][width][.precision]verb`
  （`%03d`、`%-5s`、`%5.2f`、`%*d` 等），动词 `s v d q t x X o b c f e E g G F %`

单次求值有 1000 万步上限（`MAX_EVAL_STEPS`），防死循环。

## 与 gx 的已知偏差

差分矩阵里对这些位置做了归一化，其余逐字节比对。

| 位置 | 偏差 | 原因 |
|------|------|------|
| 程序名 | `gx` → `odd`（usage / version / 错误前缀） | 名字不同，无法消除 |
| `script` 的 usage | 去掉 "Tengo " 一词；模块/`--unsafe` 两行改成"只提供安全子集 + `--unsafe` 仅为兼容" | odd 没有内嵌 Tengo 也没有模块系统，照抄原文属于虚假宣传 |
| `script` 语言 | 只实现上述子集，没有 json / times / base64 / hex / enum / os 模块 | 无 Odin 版 Tengo 绑定，按需裁剪 |
| `script` 的错误文本 | gx 报 Tengo 的 `Parse Error: ...`，odd 报自研引擎的 `syntax error: ...` | 自研引擎格式不同；差分只比"是否判错"与退出码（均为 2） |
| 非法正则的错误文本 | gx 透出 Go `regexp` 解析器原文（`error parsing regexp: ...`），odd 只回显 pattern | 自研引擎的报错格式不同；"报错 + 退出码 2" 的行为一致 |
| 遍历输出顺序 | gx 用并发 channel（顺序不定），odd 固定按文件名序 | 确定性输出更好测；内容集合相同 |
| `rename` 同名排序 | gx 用不稳定 `sort.Slice`，odd 用稳定排序 | 仅在"基名长度相同且原名互为前缀"时有理论差异 |
| Linux 的 `--ctime` | odd 用 birthtime（statx btime），gx 在 Linux 用 change time | 跨平台语义无法统一，macOS 上两者一致 |

`list -s <field> -r` 的并列项相对顺序与 gx 实测一致（夹具里放了三条 size 与
mtime 都相同的记录，见 `tests/run.sh` 的 "sort 并列 size/mtime" 用例）。

除 `script --help` 外，其余六个子命令的 `--help` 都在差分矩阵里逐字节比对。

## 交叉编译

```bash
make all         # 全部平台 → dist/odd-<平台>（10 个）
make main        # 五大主流：darwin x2 / linux amd64+arm64 / windows amd64
make extra       # linux 386/arm/riscv64、freebsd amd64+arm64
make musl        # Linux 静态变体（musl，无 glibc 依赖）
make universal   # macOS universal2（lipo 合并）
make host        # 只构建本机平台
make dist-check  # 用 file(1) 核对产物格式
make list        # 列出平台表
make distclean   # 清 dist/ 与 .build/
```

`darwin_*` 走 odin 原生链接；其余平台先 `-build-mode:obj` 再用 `zig cc` 链接
（本机 odin 的链接器不支持 linux/windows/freebsd 的交叉链接，zig 自带各平台
libc 与 mingw 导入库）。需要 zig（已验证 0.17.0）。

本机时间换算按平台分文件：`lib/time_local_unix.odin`（libc `localtime_r`/
`mktime`）与 `lib/time_local_windows.odin`（Win32 `SystemTimeToTzSpecificLocalTime`
系列，这四个符号不在 `core:sys/windows/kernel32` 的绑定里，自行声明）。

## 代码结构

```
odd/
├── main.odin              入口：os.args → app.run_main → 退出码
├── app/                   参数解析 + 七个命令的实现（可测试）
│   ├── args.odin          Option 表 / ParseSimple / ParseCommon / FormatOptions
│   ├── cli.odin           顶层分派、usage、输入错误文案
│   ├── cmd_*.odin         每个子命令一个文件
│   └── expr.odin          script 的迷你表达式引擎（词法/AST/求值）
├── engine/                walker（gitignore/glob/binary/depth）+ processor（worker pool）+ stream
├── search/                自研正则：解析 → 字节码 → 回溯 VM，含 Go 风格模板展开
├── lib/                   跨模块共享类型、sizeexpr、timeexpr、gitignore、format
│   ├── time_local_unix.odin     本地墙上时间（POSIX）
│   └── time_local_windows.odin  本地墙上时间（Win32）
├── tests/run.sh           差分矩阵（odd vs gx）
├── tools/guard.sh         静态护栏（依赖方向 / os.exit 位置 / panic / odin check）
├── Makefile               本地开发入口 + 交叉编译平台表
└── .ai-memory/            决策记录（adr/）、调研结论（findings.md）、进度
```

依赖方向单向：`main → app → engine → search → lib`，由 `tools/guard.sh` 强制。

## 性能相关的几处取舍

- **正则**：纯字面量走 `bytes.index` 整串搜索；半字面模式（`foo\d+`）用提取出的
  **前导字面字节**跳过不可能的起点（`re.prefix` + memchr），只有1k anchors 无法确定
  前缀时才逐字节跑 VM。提取规则刻意保守（只在顶层 Concat 的前导 Char 上取，
  遇到组/可选/类/断言一律放弃），保证"跳过的起点不可能产生匹配"。
- **list 排序**：`slice.stable_sort_by`（O(n log n)），比较器沿用 gx 的
  `less = !less` 反序写法。
- **lib/format**：写入式 `_to(builder)` 版本零分配，旧版每列两次分配且
  `strings.repeat` 的填充串从未释放。
- **gitignore**：pattern 字符串借用文件内容（零拷贝），行首 `\#` 转义因此不能用
  `aprintf` 拼新串——改成借用 `line[1:]`。

### 为什么不用 `core:regex`

Odin 的 core 与 vendor 都没有正则包。因此 `search/regex.odin` 自己实现了
解析器 + 回溯 VM（支持分组、命名组 `(?P<n>...)`、字符类、量词、锚点、
反向引用），并对每步执行计数，避免灾难性回溯。字面量模式走子串搜索快路径。

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 致谢

- 命令行语义、输出文本、测试用例全部来自 [gx](https://github.com/azhai/gx)
- find/replace 的设计灵感分别来自 ripgrep，rename 来自 f2
