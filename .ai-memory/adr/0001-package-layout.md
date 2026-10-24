# ADR 0001 — 按职责拆包，依赖方向单向

- 状态：已采纳
- 日期：2026-10-24

## 背景

初版把七个命令塞进单个 `main` 包，`odin test` 只能跑根包，任何一处改动都要
重新链接整个二进制；而且"命令层是否该直接读文件"这类边界问题没有答案。

参照 `../xrep` 的既有约定（它的 ADR 0006/0007 记录了从单包拆到多包的过程），
odd 从一开始就按职责拆开。

## 决策

```
main.odin → app → engine → search → lib
```

| 包 | 职责 |
|----|------|
| `lib` | 跨模块共享类型（遍历产物、命中结果、匹配区间）、sizeexpr、timeexpr、gitignore、format、常量 |
| `search` | 正则：解析 → 字节码 → 回溯 VM；模板展开 |
| `engine` | walker、processor（worker pool）、stream（stdin/文件） |
| `app` | 参数表、七个命令、表达式引擎 |
| `main` | 只做 `os.exit(app.run_main(os.args))` |

Odin 的 import 路径相对源文件所在目录解析，兄弟包互引必须靠 collection，
因此所有构建命令统一加 `-collection:odd=.`。

依赖方向由 `tools/guard.sh` 静态强制：每个包的 `import "odd:X"` 都要在
白名单里，越界即失败。`os.exit` 与 `panic` 也被同样约束。

## 后果

- 好的：`odin test ./engine` 能在毫秒级跑完 19 个用例；包边界清晰，
  比如"是否跳过二进制文件"这种问题只能落在 engine，不会散在命令层。
- 好的：拆包后"engine 反向 import app"这类架构走形能在跑差分矩阵之前被拦住。
- 代价：多一层 collection 参数；跨包共享类型必须下沉到 `lib`，有时会为了
  一个结构体而在 `lib` 里多一个文件（`lib/base.odin` 就是这种"依赖根"）。
- 代价：`odin test` 一次只跑一个包，`test.sh` 必须逐包循环。
