# findings.md — 调研与决策记录

## gx（Go 原版）行为要点（源码实证）

- 退出码：find 0/1(无命中)/2；list 0/1(无条目)/2；replace 解析失败 1、否则恒 0；
  rename 0/1(无匹配)/2(冲突未 --force)；cut/trans 0/2；script 0/1(无输出)/2。
- args.ParseSimple 智能模式：无选项且 1 参 → 模式；2 参 → 模式+路径（第二参**不是**替换串）；
  要指定替换需 `-r` 或 3 个位置参。未知选项（如 -z）按**位置参数**处理（optionMap 未命中）。
- find 的 ParseArgs 会把 Replace 前插到 Paths（2 参智能模式的遗留通道）。
- replace dry-run 打印 `[DRY-RUN] path` + 命中行 + `-> 新行`；-x 执行后同样打印明细。
  写盘失败 → stderr 红字。replace 输出恒彩色（除非 --no-color），无 TTY 探测。
- walker：默认跳过 .git/.hg/.svn/node_modules/vendor/target/build/.idea/.vscode；
  gitignore 多级继承（lazy，按目录缓存）；binary = 前 512 字节含 NUL；
  FilePattern 只作用于常规文件名（filepath.Match 语义）。
- list：`--format long` 与 `show` 实际等价（printEntry 同一分支）；
  "path" 格式在无 --show/无过滤表达式时纯路径；有则出 size/mtime/ctime 列。
  根路径自身被排除（abs 比较）。sort 稳定排序，-r 反转 less。
- cut：字段 1-based；`N-` 开放；`-M` = 1..M；hi=-1 或越界夹到行尾；
  `-d` 支持 \t \n \\ 转义；空 -d 回落 tab。行按 \n 切、剥行尾 \r。
- trans：upper/lower 为 Unicode；squeeze = Fields + join " "；reverse 为 rune 级。
- script：`-e` 包装为 `__out := (EXPR)` 并预导入安全模块；`__out` 为 string→输出、
  false/undefined→过滤、其它→fmt.Sprint。默认模块白名单，--unsafe 全开。

## Odin 环境事实（dev-2026-10，本机 M4/macOS）

- **无 core:regex**（core 与 vendor 均无）→ 必须自研正则。
- `os.File_Info` 有 creation/modification/access_time；POSIX readdir 用
  fstatat(SYMLINK_NOFOLLOW)，符号链接类型可靠。
- Linux 上 creation_time = statx btime（失败回落 mtime）；gx 的 ctime 在 Linux 用
  Ctim（change time）、darwin 用 birthtime —— **Linux 上 --ctime 语义与 gx 不同**（记录为已知差异）。
- `strings.to_upper/to_lower` 为 rune 级（Unicode），与 Go 对齐。
- 闭包**不捕获**外层变量（编译错误）→ 回调一律 rawptr user-data。
- 线程：`thread.create(proc(^Thread))` + `thread.join/destroy`；`sync.Mutex`；
  原子：`sync.atomic_add` 等（intrinsics.atomic_*）。
- `odin test` 一次只跑一个包路径；测试运行器用 Tracking_Allocator（非线程安全）→
  自建线程入口必须 `context = runtime.default_context()`（xrep ADR 0003 的教训）。
- `odin test .` 会用测试产物覆盖并删除仓库根的 ./odd（xrep 同款陷阱）→ test.sh 里
  内建自检排在 build 之后。

### 实施期补充的 Odin 事实（每条都踩过）

- **`sync.atomic_add(&x, d)` 返回加之前的值**（fetch-then-op）。`atomic_add(&n,1)-1`
  第一次得 -1 → worker pool 越界且静默不干活。直接用返回值。
- **`fmt.aprintf(format, args, allocator)` 会把 allocator 吞进 `..any`**，
  必须写 `fmt.aprintf("%s", v, allocator = alloc)`。否则既泄漏又在输出里
  掺 `%!(EXTRA ...)`。
- **`defer` 是块作用域**：`if cond { defer delete(p) }` 在离开 if 块时就执行。
  `-F` 固定串的悬垂就死在这里。
- **struct 字段必须逗号分隔**（Go 的换行分隔不合法）；无裸类型嵌入，用 `using name: T`。
- **无 `string → []rune` 转换**，要 rune 处理就迭代 + `strings.Builder`。
- **`time.diff(start, end)` 返回 end - start**（名字与实际相反）。
- **`core:time` 的 `date()` / `clock_from_time()` 是 UTC**；本地时间必须走
  `posix.localtime_r` / `posix.mktime`（`tm_year` 是 1900 偏移、字段为 `i32`）。
- **`switch` 必须穷尽枚举**，`case:` 默认分支**不算**覆盖；否则 `#partial switch`。
- **`for e in slice` 不能对 `e` 取地址**，要 `for &e in slice`。
- **`strings.replace_all(s, old, new, alloc) -> (string, bool)`**；
  限次版本是 `strings.replace(s, old, new, count, alloc)`。
- **`strings.to_string(builder)` 转移所有权**，之后不能再 `builder_destroy`。
- **`testing.expect` 只收 `msg: string`**；带格式用 `testing.expectf`。
- **选项表必须可寻址**：proc 返回的数组不可切片，测试里要用包级变量。
- **线程入口必须 `context = runtime.default_context()`**，否则继承
  Tracking_Allocator（无锁 map）→ 并发写坏 → SIGBUS。
- **本机沙箱把 `touch` / `SetFile` 包装成 broker IPC 调用**（`ps` 也被禁）。
  高频调用会把测试从秒级拖到分钟级，偶发永久挂起 → 夹具只建一次或用 cp 克隆。
- **`SetFile -d` 可改 birthtime，`touch -h -t` 可改符号链接自身 mtime**；
  但 birthtime 无法通过 `cp` 复制 → list 夹具不能靠克隆复用。
- macOS APFS 默认大小写不敏感：不能只靠"大小写不同"造两个文件做测试夹具。
- **切片字面量不能写在 `for ... in` 的头部**（`Expected 1 expression`）→ 先赋给
  局部变量。struct 字段也不能叫 `in`。
- **`fmt.bprintf` 收 `[]u8`**；要往 Builder 写用 `fmt.sbprintf`。
- **`core:slice` 才有 `stable_sort_by`**（`core:sort` 里只有不稳定的 quick_sort
  系列），且没有 user_data 版本 → 比较器只能读包级变量（排序单线程，安全）。

### 交叉编译（make all）暴露的事实

- 本机 odin 的链接器只支持本机平台 + `darwin_amd64`；linux/windows/freebsd 必须
  `-build-mode:obj` + `zig cc -target <triple>` 链接（zig 自带 libc/mingw 导入库）。
- Windows 需要 `_fltused` 垫片（mingw 未定义）+ `-lbcrypt`（Odin runtime 的随机源
  `BCryptGenRandom`）。
- **`core:sys/posix` 在 Windows 目标下不导出 `time_t` / `tm` / `localtime_r` /
  `mktime`** → 本地时间换算必须按平台分文件（`time_local_unix.odin` /
  `time_local_windows.odin`，用 `#+build` 隔离，逗号 = OR）。
- Win32 的 `TzSpecificLocalTimeToSystemTime` / `LocalFileTimeToFileTime` **不在**
  `core:sys/windows/kernel32` 的绑定里 → 自行 `foreign import kernel32` 声明用到的
  四个符号（结构体也精简重声明，避免拖进整个 windows 包）。

## 单元测试抓到的真实缺陷（都是先有测试才发现的）

1. `format_fixed_width` 的 `strings.repeat(" ", pad)` 中间串从未释放 → 每列泄漏。
   修复：改为写入式 `format_*_to(builder)`，零分配。
2. `sizeexpr` 每次 `strings.to_upper(unit)` 泄漏 → 改成按首字节手工比对 ASCII。
3. `gitignore` 处理 `\#` 转义时用 `aprintf` 拼新串 → 既破"pattern 借用 content"
   的约定又泄漏；改成借用 `line[1:]`（行内 `\#` 在 gitignore 里本就无需转义）。
4. **未闭合字符串字面量被静默当成空串**：`__out := "unterminated` 在 odd 里成功，
   gx 报错退出 2。修复：Lexer 记 `err`，`parse_program` 收尾再检查一次。
5. 正则前导跳过在 ci 模式下只按小写字形态做 memchr → `-i` 半字面模式（如
   `Foo\d+`）漏掉 "FOO7"。修复：首字节同时找大小写两种形态取最近者。

## 决策

1. **正则引擎**：AST + 编译为字节码 + 回溯 VM（Split/Save/Jmp/Char/Class/Backref）。
   左优先序（与 Go regexp 默认一致）。字面量模式走子串搜索快路径。
2. **遍历**：顺序 + 每层按名排序（= Go WalkDir 的词法序），输出确定性；
   gx 为并发 channel（序不定）。find/replace 仍支持 -j 并行处理文件，但按文件序输出。
3. **script**：迷你表达式引擎（递归下降），变量 line/lineno/filename/content，
   内置 text.to_upper/to_lower/trim/contains/count/replace/has_prefix/has_suffix、
   fmt.sprintf、math.abs/min/max。不支持 json/times/base64/hex/enum/os/rand
   （ponytail: 有界裁剪，README 明示）。
4. **ctime**：直接用 File_Info.creation_time（跨平台一致，语义差异记录在 README）。
