package app

// ============================================================================
// cli.odin — 顶层分派（复刻 gx main.go 的 runMain）
//
// 职责：按 argv[1] 分派子命令；处理 -h/--help/-V/--version 与未知命令；
//       把子命令的 argv（去掉二进制名与子命令名）交给各命令的 parse 入口。
//
// 退出码（gx 原样，见 .ai-memory/findings.md）：
//   0 — 有输出/命中
//   1 — 无命中（grep 约定；replace 解析失败也是 1）
//   2 — 参数或运行期错误
//
// 各命令的实现文件：cmd_find / cmd_replace / cmd_rename / cmd_cut /
// cmd_trans / cmd_list / cmd_script（参数表与 parse 在同文件，run 为入口）。
// ============================================================================

import "core:fmt"
import "core:os"
import "odd:lib"

// run_main — 可测试的入口：返回进程退出码。
// argv 含二进制名（argv[0] = "odd"）。
run_main :: proc(argv: []string) -> int {
	if len(argv) < 2 {
		print_top_usage_to(os.stdout)
		return 2
	}

	command := argv[1]
	// 交给子命令的 argv：去掉二进制名与子命令名（gx 在 main 里把 os.Args
	// 重设为 argv[1:]，子命令再取 os.Args[1:]——净效果就是下面的 sub_argv）。
	sub_argv := argv[2:]

	switch command {
	case "find":
		return run_find(sub_argv)
	case "list":
		return run_list(sub_argv)
	case "replace":
		return run_replace(sub_argv)
	case "rename":
		return run_rename(sub_argv)
	case "cut":
		return run_cut(sub_argv)
	case "trans":
		return run_trans(sub_argv)
	case "script":
		return run_script(sub_argv)
	case "-h", "--help":
		print_top_usage_to(os.stdout)
		return 0
	case "-V", "--version":
		// 与 gx 的 Version() 同形：`gx version %s (commit: %s)` → 此处换成 odd。
		fmt.printf("odd version %s (commit: %s)\n", lib.ODD_VERSION, lib.ODD_COMMIT)
		return 0
	case:
		fmt.fprintf(os.stderr, "Unknown command: %s\n\n", command)
		print_top_usage_to(os.stderr)
		return 2
	}
}

// print_top_usage_to — 顶层用法（gx printUsageTo 原样，二进制名替换为 odd）。
//
// 与 gx 的唯一文本偏差：script 一行去掉了 "Tengo " 一词。gx 内嵌 Tengo
// 解释器，odd 用的是自研迷你表达式引擎（app/expr.odin），只覆盖脚本子集，
// 写 "Tengo" 属于虚假宣传。差分脚本对这一处做已知偏差归一化，其余逐字比对。
print_top_usage_to :: proc(w: ^os.File) {
	fmt.fprintln(w, `odd - A handy text-processing utility (sed/awk style)

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

Use "odd <command> --help" for command-specific options.

Examples:
  odd find "pattern" ./src
  odd list -g "*.go" ./src
  odd replace "old" "new" ./src -x
  odd rename "foo" "bar" -x
  cut -f 2 -d , file.csv
  cat file | odd trans upper
  echo "hi" | odd script -e 'text.to_upper(line)'`)
}

// print_input_error — 复刻 gx 的输入错误文本（cut/trans 共用）。
// gx 的错误链：OpenInput 包一层 `open %s: %w`，ReadAll 对读错误再包一层
// `read %s: %w`；而 Go 的 os.Open/read 错误自身已含 `open <p>: ...` /
// `read <p>: ...`，于是命令层打印的文本里路径出现两次：
//   `<cmd>: open <p>: open <p>: no such file or directory`
//   `<cmd>: read <p>: read <p>: is a directory`（输入是目录时）
// Odin 的 read_all 不返回 errno，这里按存在性/类型推断复刻两种常见形态
// （目录探测用 stat 跟随符号链接——/tmp 这类 symlink-to-dir 也是目录）；
// 其余形态尽力而为。
print_input_error :: proc(cmd: string, path: string) {
	if fi, err := os.stat(path, context.temp_allocator); err == nil {
		defer os.file_info_delete(fi, context.temp_allocator)
		if fi.type == .Directory {
			fmt.fprintf(os.stderr, "%s: read %s: read %s: is a directory\n", cmd, path, path)
			return
		}
	}
	fmt.fprintf(os.stderr, "%s: open %s: open %s: no such file or directory\n", cmd, path, path)
}
