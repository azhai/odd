package app

// ============================================================================
// cmd_trans.odin — trans 子命令（复刻 gx cmd/trans）
//
// 职责：对每行输入应用内置变换（upper/lower/trim/squeeze/reverse）。
//       stdin/stdout 过滤器：读一个文件（无路径或 "-" 时读 stdin）。
//
// 与 gx 的对齐点（含怪癖）：
//   * upper/lower 为 Unicode（rune 级）；squeeze = Fields + join " "；
//     reverse 为 rune 级反转
//   * 路径解析三岔（gx 原样）：
//       ReplaceSet 且 Replace != "" → 用 Replace（第 2 位置参）
//       否则 Paths[0] != "."        → 用 Paths[0]
//       否则                        → stdin
//     即 `trans upper .` 读的是 stdin 而不是目录
//   * 退出码：0 成功 / 2 参数或 IO 错误
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strings"
import "odd:engine"

// 行变换函数类型：入参为不含换行的行，返回**新建**字符串（调用方负责 delete）。
Trans_Fn :: proc(line: string) -> string

// trans_upper / trans_lower — 包装 strings.to_upper/to_lower。
// 原函数签名为 (s, allocator) -> (string, err)，与 Trans_Fn 不匹配；
// #optional_allocator_error 允许在单值上下文丢弃 err。
trans_upper :: proc(s: string) -> string {
	return strings.to_upper(s)
}

trans_lower :: proc(s: string) -> string {
	return strings.to_lower(s)
}

// trans_trim — trim 的分配化包装。strings.trim_space 返回的是入参视图
// （零分配），与其它变换的“新建字符串”语义不一致；统一走 clone，
// 让 run_trans 的 delete(transformed) 对所有变换都安全。
trans_trim :: proc(s: string) -> string {
	return strings.clone(strings.trim_space(s))
}

// trans_squeeze — 折叠连续空白为单个空格并去首尾（复刻 gx squeeze：
// strings.Fields + strings.Join(fields, " ")）。
trans_squeeze :: proc(s: string) -> string {
	fields := strings.fields(s)
	defer delete(fields)
	return strings.join(fields[:], " ")
}

// trans_reverse — rune 级反转（复刻 gx reverse）。
// Odin 不支持 string → []rune 直接转换，用 `for r in s` 逐 rune 收集后
// 逆序 write_rune 重建。
trans_reverse :: proc(s: string) -> string {
	runes: [dynamic]rune
	defer delete_dynamic_array(runes)
	for r in s {
		append(&runes, r)
	}
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	for i := len(runes) - 1; i >= 0; i -= 1 {
		strings.write_rune(&b, runes[i])
	}
	return strings.to_string(b) // 所有权转移给调用方
}

// trans_lookup — 变换名 → 函数（复刻 gx transforms map）。
// 返回 nil 表示未知变换（调用方按 gx 口径报错退出 2）。
// 约定：所有函数都返回**新建**字符串（调用方负责 delete）。
trans_lookup :: proc(name: string) -> Trans_Fn {
	switch name {
	case "upper":
		return trans_upper
	case "lower":
		return trans_lower
	case "trim":
		return trans_trim
	case "squeeze":
		return trans_squeeze
	case "reverse":
		return trans_reverse
	}
	return nil
}

// trans 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Trans_Config :: struct {
	using common: Common_Config,
	transform: string, // 变换名（第一个位置参）
}

// trans 默认配置（gx trans.NewConfig）。
trans_new_config :: proc() -> Trans_Config {
	return Trans_Config{
		common = {dry_run = true},
	}
}

// trans 参数解析（gx trans.ParseArgs：裸 ParseSimple；无自有选项）。
trans_parse :: proc(argv: []string, c: ^Trans_Config) -> bool {
	return parse_simple(argv, &c.common, []Option{}, trans_print_usage)
}

// trans 用法（gx trans.printUsage）。
trans_print_usage :: proc() {
	// 注意用 println 而不是 print：gx 的 printUsage 走 fmt.Fprintln，
	// 结尾有一个换行。用 print 会让 `trans --help` 的输出少一个 \n，
	// 差分矩阵（逐字节比对）会立刻抓到。
	fmt.println(`trans - Apply a text transformation to each line

Usage: trans <TRANSFORM> [FILE]

Transforms:
  upper    Uppercase
  lower    Lowercase
  trim     Strip leading/trailing whitespace
  squeeze  Collapse whitespace runs to a single space, trim ends
  reverse  Reverse the string (rune-wise)

When FILE is omitted or '-', reads from stdin.

Examples:
  odd trans upper file.txt
  cat file | odd trans lower
  odd trans squeeze -`)
}

// run_trans — trans 入口（完整实现）。退出码：0 成功 / 2 参数或 IO 错误。
run_trans :: proc(argv: []string) -> int {
	c := trans_new_config()
	defer delete_dynamic_array(c.paths)
	if !trans_parse(argv, &c) {
		return 2
	}

	// ParseCommon 的位置参链：arg[0] = transform（Pattern），arg[1] = 输入文件。
	// 路径解析按 gx 三岔（见文件头）：注意 "." 显式传入时也算默认 → stdin。
	c.transform = c.pattern
	paths := make([]string, 1)
	defer delete(paths)
	switch {
	case c.replace_set && c.replace != "":
		paths[0] = c.replace
	case len(c.paths) > 0 && c.paths[0] != ".":
		paths[0] = c.paths[0]
	case:
		paths[0] = "-" // stdin
	}

	fn := trans_lookup(c.transform)
	if fn == nil {
		fmt.fprintf(
			os.stderr,
			"trans: unknown transform %q (available: upper lower trim squeeze reverse)\n",
			c.transform,
		)
		return 2
	}

	data, _, read_ok := engine.read_all(paths)
	defer delete(data)
	if !read_ok {
		print_input_error("trans", paths[0])
		return 2
	}

	lines, scan_ok := scan_lines(data)
	defer delete_dynamic_array(lines)
	out: [dynamic]u8
	defer delete_dynamic_array(out)
	for line in lines {
		transformed := fn(line)
		append(&out, ..transmute([]u8)transformed)
		delete(transformed)
		append(&out, '\n')
	}
	os.write(os.stdout, out[:])
	if !scan_ok {
		// gx：scanner.Err() != nil → "trans: bufio.Scanner: token too long"，退出 2
		fmt.fprintln(os.stderr, "trans: bufio.Scanner: token too long")
		return 2
	}
	return 0
}
