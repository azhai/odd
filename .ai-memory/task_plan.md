# task_plan.md — odd（gx 的 Odin 复刻）

## 目标

参照 `../gx`（Go 版文本处理工具）的**全部命令行参数**，用 Odin 复刻一份，
代码结构与工程约定参照 `../xrep`（子目录包 + collection + 三层测试 + 静态护栏）。

二进制名：`odd`。包结构：`main → app → engine → search → lib`。

## 命令清单（与 gx 一一对应）

- [x] find    内容搜索（grep 风格）
- [x] list    目录列举（ls 风格，过滤/排序/格式）
- [x] replace 搜索替换（dry-run 默认）
- [x] rename  批量重命名（f2 风格，冲突检测）
- [x] cut     字段提取（-f 子集）
- [x] trans   行变换（upper/lower/trim/squeeze/reverse）
- [x] script  脚本过滤（**Odin 无 Tengo → 迷你表达式引擎，子集见 README**）

## 阶段

1. [x] 骨架：目录、build.sh / test.sh / Makefile、main 分派、.ai-memory
2. [x] lib：sizeexpr / timeexpr / gitignore / format / base
3. [x] search：正则引擎（解析 + 回溯 VM + 捕获组 + $1 展开 + 字面量快路径）+ 差分测试
4. [x] engine：walker（gitignore/glob/binary/depth）/ processor（-j worker pool）/ stream
5. [x] app/cli：ParseSimple / ParseCommon / Option 表 / FormatOptions
6. [x] find / replace / rename
7. [x] cut / trans
8. [x] list
9. [x] script（expr 引擎 + 命令）
10. [x] 测试：逐包 odin test + tests/run.sh 矩阵 + verify.sh + README + AGENTS + ADR
11. [x] Makefile 交叉编译（`make all` → 10 个平台；Windows 侧本地时间分文件实现）
12. [x] 补单测：lib（28 条，此前 0）+ app/expr（13 条，此前 0）
13. [x] 算法优化：正则前导字面量跳过、list 排序 O(n log n)、format 零分配

## 完成状态（2026-10-25）

- 单测：`lib` 28、`search` 22、`engine` 19、`app` 30（合计 99，零泄漏）
- 差分矩阵：179 条全绿（顶层 7 + cut 22 + trans 13 + find 9 + replace 34 +
  rename 21 + list 41 + script 32）
- 交叉编译：darwin arm64/amd64、linux amd64/arm64/386/arm/riscv64、
  windows amd64、freebsd amd64/arm64 全部产出对应格式的二进制
- 静态护栏：依赖方向 / os.exit 位置 / panic / odin check 全通过
- `./verify.sh` 约 1 分 55 秒

## 后续可选项（未做）

- script 扩到 for 循环 / 更多模块（expr.odin 的 AST 已预留语句类型）
- walker 深度改为递归递进计数（避免每个条目重算 path_components）
- 差分矩阵加 FILTER 正则支持（现在是纯子串匹配）

## 关键决策（详见 findings.md / adr/）

- ADR 0001 拆包与依赖方向
- ADR 0002 自研正则（Odin 无 core:regex）
- ADR 0003 script 用迷你表达式引擎
- ADR 0004 差分测试作为验收主线
- ADR 0005 遍历与输出顺序确定化

## 恢复点

断点续作时：读本文件 + progress.md 最后一条，从对应阶段继续。
