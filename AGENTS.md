# AGENTS.md — odd 协作规范

给在本仓库里干活的 AI / 人的操作手册。**开工前先读这一页**，尤其是
「Odin 踩坑清单」——那些坑都实际踩过，每条都配了症状与修法。

## 这个项目的验收标准是什么

不是"能跑"，而是**与 gx 行为一致**。所以：

- 任何命令层改动，最后一关是 `./tests/run.sh`（odd vs gx 逐字节比对）
- 任何函数层改动，`odin test` 对应包必须全绿（内存追踪开启，泄漏会报错）
- 两者都过还要过 `./tools/guard.sh`（依赖方向等静态约束）
- 一条命令全跑：`./verify.sh`（约 2 分钟）

改完不跑验证就宣称完成，是本仓库最严重的错误。

## 目录与依赖方向

```
main.odin → app → engine → search → lib
```

单向，`tools/guard.sh` 强制。具体：

| 包 | 允许依赖 | 职责 |
|----|----------|------|
| `lib` | 无 | 跨模块共享类型、sizeexpr/timeexpr/gitignore/format、常量 |
| `search` | `lib` | 自研正则（解析 → 字节码 → 回溯 VM）+ Go 风格模板展开 |
| `engine` | `lib` `search` | walker（遍历/gitignore/glob/binary/depth）、processor（worker pool）、stream（stdin/文件） |
| `app` | `lib` `search` `engine` | 参数表 + 七个命令 + 表达式引擎 |
| `main` | `app` | 只做 `os.exit(app.run_main(os.args))` |

新代码放哪个包，先问"它依赖谁"：只依赖 lib → 放 lib；要遍历文件 → engine；
只服务某个子命令 → app。

## 构建与测试

```bash
./build.sh                  # → bin/odd（注入 git commit）
make -C . all               # 交叉编译 10 个平台 → dist/（见 README）
./test.sh                   # 全部包单测
./test.sh ./engine          # 单包
ODIN_TEST_NAMES=engine.test_walk_depth ./test.sh ./engine
./tests/run.sh              # 差分矩阵
FILTER=sprintf ./tests/run.sh   # 只跑描述含该子串的用例（纯子串匹配，不支持正则）
CASE_MODE=files run_case …      # 在 run.sh 内：只比退出码与工作树，忽略 stdout/stderr
VERBOSE=1 ./tests/run.sh        # 打印每条命令
./verify.sh                 # 护栏 + 单测 + 差分
```

`CASE_MODE=files` 专门用于"两边都报错但文案不同"的已知偏差（README 偏差表里的
那几条）：行为一致的那部分（退出码、有没有改动文件）仍然被守住。

`ODIN_CC=/usr/bin/clang` 必须显式设置（PATH 里的 clang 被 Android NDK 占用，
会链接失败）。三个脚本都已内置，但手工敲 `odin build` 时要记得。

## 改一个命令的标准流程

1. 先看 `../gx` 里对应实现，确认它的真实行为（不要凭直觉，gx 有不少怪癖：
   2 参智能模式、`-j 0` 在 replace 下是零 worker、`find` 把 replace 前插回
   paths 等，详见 `.ai-memory/findings.md`）
2. 改 `app/cmd_<name>.odin`；如果需要新的底层能力，先改 `lib`/`search`/`engine`
3. 补一条单测到对应 `*_test.odin`（函数级）
4. 补差分用例到 `tests/run.sh`（行为级，优先覆盖边界：空输入、无匹配、越界、
   报错路径、退出码）
5. `./verify.sh` 全绿才算完成

新增差分用例时，用例描述用中文短名（`"sprintf"`、`"cut 字段 0"`），
保持能一眼看出测的是什么。

## Odin 踩坑清单

以下全部是实际踩过并修复的，症状写在前面，方便对号入座。

### 1. `sync.atomic_add` 返回**旧值**

```odin
n := sync.atomic_add(&counter, 1)   // n 是加之前的值
// 错：atomic_add(&counter, 1) - 1  → 永远 -1（第一次返回 0，再减 1）
```

写 worker pool 取任务时踩过：`i := atomic_add(&pool.next,1) - 1` 第一次拿到 -1，
越界后整个池子静默不干活。正确写法是直接用返回值。

### 2. `fmt.aprintf` 的 allocator 必须写成具名实参

```odin
fmt.aprintf("%s", v, alloc)              // 错：alloc 被 ..any 吞掉，内容变 "%!(EXTRA ...)"
fmt.aprintf("%s", v, allocator = alloc)  // 对
```

`args: ..any` 会把位置实参全吃进去，allocator 落到默认 `context.allocator`
（→ 泄漏 + 输出里混入 `%!(EXTRA ...)`）。

### 3. `defer` 是**块作用域**，不是函数作用域

```odin
if c.fixed_string {
    quoted = search.regex_quote_meta(pattern)
    defer delete(quoted)      // 离开这个 if 块就执行了！
}
// 这里 quoted 已经悬垂
```

踩过的现场：`-F` 固定串全部失效（打印空），因为 `delete` 在编译前就把串释放了。
函数级资源要提到函数顶部的 `defer { if quoted != "" { delete(quoted) } }`。

### 4. struct 字段必须逗号分隔

```odin
S :: struct { a: int, b: string }   // 对
S :: struct { a: int  b: string }   // 错（Go 风格换行分隔不合法）
```

### 5. 没有裸类型嵌入，用 `using`

```odin
Config :: struct { using common: Common_Config, extra: bool }
```

约定：`Common_Config` 必须是子命令配置结构的**第一个字段**，`args.odin` 靠
`rawptr(&c.common) == rawptr(&c)`（首字段地址等价）把 ctx 转回子命令类型。

### 6. 没有 `string ↔ []rune` 转换

要按 rune 处理就 `for r in s { ... }` + `strings.Builder`。`strings.to_upper/to_lower`
是 rune 级的（与 Go 一致），可以直接用。

### 7. `time.diff(a, b)` 返回 **b - a**

名字和实际相反。反了会得到负数时长，表现为时间过滤全部失效。

### 8. `core:time` 的 `date()` / `clock_from_time()` 是 **UTC**

要本地时间必须走 libc：`posix.localtime_r` / `posix.mktime`（`tm_year` 是 1900 偏移、
字段是 `i32`）。`lib/timeexpr.odin` 里就是这么做的，别改回去。

### 9. `switch` 必须穷尽枚举，否则用 `#partial switch`

```odin
switch v.kind { case .Int: ...; case: ... }   // 错：Unhandled switch cases: Undef Str Bool
#partial switch v.kind { case .Int: ... }     // 对
```

注意 `case:`（默认分支）**不算**覆盖剩余枚举值。

### 10. 区间 `for e in` 不能取地址

```odin
for e in res.entries  { &e }    // 错：Cannot take the pointer address of 'e'
for &e in res.entries { ... }   // 对
```

### 11. `strings.replace_all` 签名是 `(s, old, new, allocator) -> (string, bool)`

而 `strings.replace(s, old, new, count, allocator)` 才是限次版本。
把它当第二位置实参传给自定义函数会报 `Too many arguments`。

### 12. `strings.to_string(builder)` **转移所有权**

返回的串就是 builder 的底层数组。此后 `strings.builder_destroy(&b)` 会释放它 →
调用方拿到悬垂串。转移后就别再 destroy。

### 13. `testing.expect` 只收 `msg: string`

带格式参数用 `testing.expectf(t, cond, "期望 %v 实际 %v", a, b)`。

### 14. 选项表必须可寻址

```odin
find_options() -> [10]Option          // 返回值不可切片
FIND_OPTIONS: [10]Option              // 包级变量，可 []Option
```

测试里要传 `[]Option` 时用包级变量，别用 proc 返回值。

### 15. `odin test` 一次只接受一个路径

`odin test .` 只跑根包；子包要逐个跑（`test.sh` 已经这么做了）。

### 16. 线程入口必须重置 context

```odin
worker :: proc(arg: rawptr) {
    context = runtime.default_context()   // 否则继承 Tracking_Allocator → SIGBUS
}
```

Odin 的 `mem.Tracking_Allocator` 内部是无锁 map，多个 worker 并发分配会写坏它。

### 17. 本机 `touch` / `SetFile` 被沙箱 shim 包装

在 `tests/run.sh` 里高频调用 `touch`/`SetFile` 会把用例从秒级拖到分钟级，
偶发永久挂起。所以：只读命令的夹具**只建一次**，会写盘的命令用「母版 + `cp -a` 克隆」。

### 18. 切片字面量不能直接写在 `for ... in` 的头部

```odin
for _, s in []string{"a", "b"} { ... }   // 错：Expected 1 expression
xs := []string{"a", "b"}
for s in xs { ... }                      // 对
```

写单测批量遍历期望值时最容易踩。同理，struct 字段不能叫 `in`（保留字）。

### 19. `fmt.bprintf` 收 `[]u8`，要写 Builder 得用 `fmt.sbprintf`

```odin
fmt.bprintf(b, "%d", n)    // 错：Cannot assign '^Builder' to '[]u8'
fmt.sbprintf(b, "%d", n)   // 对（b: ^strings.Builder）
```

### 20. 交叉编译时 `core:sys/posix` 不提供时间符号

Windows 目标下 `posix.time_t` / `posix.tm` / `posix.localtime_r` / `posix.mktime`
全部不存在（包本身能编译，只是没这些声明）。凡是依赖 libc 的东西都要按平台分
文件实现，用 `#+build darwin, linux, freebsd` / `#+build windows` 隔离
（逗号是 OR，多行是 AND）。`make all` 是唯一的检查手段 —— 本机编译发现不了。

## 代码风格

- 注释写"为什么"，不写"做了什么"（代码已经说了）。文件头写职责边界与
  与 gx 的对齐点。
- 每个 `cmd_*.odin` 的文件头必须列出：选项个数、默认值、退出码、gx 的怪癖。
- 标识符 snake_case（Odin 惯例），类型 Camel_Snake（`Find_Config`）。
- 不引入 `panic`：CLI 对用户输入只能报错 + 返回退出码（`tools/guard.sh` 会拦）。
- 不用 `os.exit` 除 `main.odin` 之外的任何地方（退出码要能被单测断言）。

## 文档维护

- `.ai-memory/findings.md` — 调研结论（gx 行为实证、Odin 环境事实、决策）
- `.ai-memory/task_plan.md` — 任务清单与阶段
- `.ai-memory/progress.md` — 会话日志，只记"有跨会话价值的进展"
- `.ai-memory/adr/` — 重大取舍的决策记录
- `README.md` — 面向使用者；**已知偏差表必须与实现的当前状态一致**

改行为时同步改 README 的偏差表；否则下一个人（或下一个 AI）会以为那是 bug。
