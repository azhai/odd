# progress.md — 会话日志

## 2026-10-24

- 通读 /opt/repos/gx 全部源码（main/args/walker/processor/regex/stream/common/cmd/*）
  与 /opt/repos/xrep 全部约定（AGENTS.md/README/包结构/构建脚本）。
- 确认 Odin dev-2026-10 环境事实（无 regex、闭包不捕获、File_Info 字段、线程 API）。
  详见 findings.md。
- 建立目录骨架 lib/search/engine/app/tests/tools/.ai-memory 与 task_plan.md。
- 开始 lib 包实现。
- 完成 lib / search / engine / app 四个包与七个命令，全部差分验证通过。
- 补齐工程骨架：build.sh（注入 git commit）、test.sh（逐包 + 内存追踪）、
  Makefile、verify.sh、tools/guard.sh（依赖方向 / os.exit / panic / odin check）。
- tests/run.sh：把临时差分脚本合并成正式矩阵，172 条用例分八个 section。
  夹具策略：只读命令只建一次，写盘命令用「母版 + cp -a 克隆」。
- 文档：README.md（命令参考 + 已知偏差表）、AGENTS.md（含 17 条 Odin 踩坑）、
  ADR 0001-0005。
- 验收：guard + 单测（53）+ 差分（172）全绿，./verify.sh 约 1 分 50 秒。

### 本阶段修掉的根因（都已写入 AGENTS.md 踩坑清单）

- `sync.atomic_add` 返回**旧值** → `-1` 导致 worker pool 静默不干活
- `fmt.aprintf(fmt, args, alloc)` 的 allocator 被 `..any` 吞掉 → 泄漏 + `%!(EXTRA)`
- `defer` 是块作用域 → `-F` 固定串在编译前就悬垂，输出全空
- `time.diff(a,b)` 返回 b-a（名字相反）+ `date()` 是 UTC → list 时间过滤全错
- walker 深度用树层数而非 gx 的路径分量数 → `-L` 不符
- 正则模板缺 Go `Expand` 语义（命名组、最长标识符、禁止前导零）→ rename 分组错
- `fmt.sprintf` 只按「% + 单字符」解析 → `%03d` 原样输出；改为解析
  flags/width/precision 后交给 Odin 的 fmt

## 2026-10-25

- **Makefile 交叉编译**：照 xrep 的做法加平台表（DEFINE_TARGET），`make all` 出
  10 个平台（darwin x2 原生链接 + linux/windows/freebsd 共 8 个走 obj→zig cc），
  另带 main/extra/musl/host/universal/dist-check/list/checksums/distclean。
  与 xrep 的一处刻意差异：产物格式核对叫 `dist-check`（`check` 已被
  "odin check 只做类型检查"占用）。
- `make all` 立刻暴露 Windows 目标编译不过：`core:sys/posix` 不导出
  `time_t/tm/localtime_r/mktime`。按平台拆 `lib/time_local_{unix,windows}.odin`
  （`#+build` 隔离），Windows 侧自行声明用到的 4 个 Win32 时间转换符号。
- **补单测**：新增 `lib/lib_test.odin`（28 条，lib 此前零覆盖）与
  `app/expr_test.odin`（13 条，expr.odin 是最大单文件但此前零覆盖）。
  合计 lib 28 / app 30 / engine 19 / search 22 = 99 条，全部零泄漏。
- 这批单测当场抓出 5 个真实缺陷（详见 findings.md "单元测试抓到的真实缺陷"）：
  format 填充串泄漏、sizeexpr to_upper 泄漏、gitignore `\#` 转义泄漏、
  未闭合字符串被静默当空串（与 gx 的退出码 2 不一致）、正则前导跳过的 ci 漏洞。
- **算法/数据结构优化**：
  * 正则：新增 `re.prefix`（前导字面字节）+ memchr 起点跳过，半字面模式
    （`foo\d+`）不再按字节跑 VM；提取规则刻意保守（只取顶层 Concat 的前导 Char），
    保证跳过的位置不可能产生匹配。新增 4 条针对它的单测（含 8KB 长行）。
  * list 排序：插入排序 O(n²) → `slice.stable_sort_by` O(n log n)；为验证等价性，
    在差分夹具里加了三条 size 与 mtime 都相同的记录 + 4 条"并列排序"用例，
    实测与 gx 的 `SliceStable + !less` 结果一致。
  * lib/format：改为写入式 `_to(builder)` 零分配 API（旧版每列两次分配且泄漏）。
- 差分矩阵扩到 179 条（+4 并列排序、+3 脚本词法/运行期错误，后者用
  `CASE_MODE=files` 只比退出码，因为错误文案属已记录偏差）。
- 验收：guard + 单测（99）+ 差分（179）全绿，./verify.sh 约 1 分 55 秒。
