# ADR 0003 — script 用迷你表达式引擎，而不是绑定 Tengo

- 状态：已采纳
- 日期：2026-10-24

## 背景

gx 的 `script` 命令内嵌 [Tengo](https://github.com/d5/tengo)（纯 Go 实现的脚本语言），
`-e` 内联表达式、`-f` 完整脚本、`--whole` 整文件模式，结果写 `__out`。

Odin 没有 Tengo 绑定，也没有等价的嵌入式脚本语言。三条路：

1. 自己写一个 Tengo 解释器 —— 工作量远超"复刻一个 CLI"
2. 绑定 Lua / QuickJS —— 引入 C 依赖 + FFI 复杂度
3. 写一个只覆盖常见用法的小表达式引擎

## 决策

`app/expr.odin`：词法 → AST → 递归下降解析 → 求值（`Env{vars: map[string]Val}`）。
支持：

- 运算符 `+ - * / %`、比较、`&&` `||` `!`、一元 `-`、三元 `?:`（右结合）、`:=`、注释
- 字面量：整数、浮点、双引号（含转义）、反引号原样、`true/false/undefined`
- 内建 `len / string / int / import`
- `text.*`：大小写、trim 系列、contains / has_prefix / has_suffix / index /
  repeat / replace(s,old,new,n) / atoi / itoa / re_match / re_replace
- `fmt.sprintf`：完整 `%[flags][width][.precision]verb`，动词 `s v d q t x X o b c f e E g G F %`

两个关键的兼容性让步：

- **`import` 是空绑定**。gx 的 `-f` 脚本必须写 `text := import("text")`，否则
  报 unresolved reference。让 `import` 返回空串即可让这类脚本原样跑通，
  而模块函数本来就是全局可见的。
- **`-e` 包装成 `__out := (EXPR)`**，与 gx 一致；`-f` 必须自己赋 `__out`。

求值有 1000 万步上限，防死循环。

## 后果

- 好的：无外部依赖，`script` 的常用场景（行过滤、格式化、正则替换）都能覆盖，
  差分矩阵 29 条全绿。
- 好的：`fmt.sprintf` 的宽度/精度是直接解析出 spec 后交给 Odin 的 fmt，
  不需要自己实现数字格式化，`%03d` / `%-5s` / `%5.2f` 天然正确。
- 代价：不是 Tengo。`json` / `times` / `base64` / `hex` / `enum` / `os` 模块
  和 `for` / `if` 语句块 / 函数定义都不支持，复杂脚本跑不了。
  README 里明确列出边界与偏差，usage 文案也去掉了 "Tengo" 一词。
- 代价：`--unsafe` 与 `--timeout` 只是参数层占位（没有模块系统、没有沙箱），
  行为上不产生差异。
