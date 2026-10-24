package app

// ============================================================================
// cmd_script.odin — script 子命令（复刻 gx cmd/script 的参数层）
//
// 职责：参数表 + parse + 用法 + Go 风格时长解析；run 在任务 #9 用迷你
//       表达式引擎补齐（gx 用 Tengo，odd 用自研 expr 引擎，函数集为有界
//       子集，见 .ai-memory/findings.md 决策 3）。
//
// 与 gx 的对齐点：
//   * 选项 5 个：-e/--expr、-f/--file、--whole、--unsafe、--timeout
//   * 默认 timeout = 1s；--timeout 解析失败 → 解析整体失败（退出 2）
//   * parse 为裸 ParseSimple（Common_Config 仅为占位，script 不用
//     pattern/replace/paths 语义，输入路径在任务 #9 按 gx 口径解析）
//   * 退出码：0 有输出 / 1 无输出 / 2 参数或运行期错误
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "odd:engine"

// script 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Script_Config :: struct {
	using common: Common_Config,
	expr:    string,        // -e：内联表达式
	file:    string,        // -f：脚本文件
	whole:   bool,          // --whole：整文件模式（awk 风格）
	unsafe:  bool,          // --unsafe：放开全部模块（odd 中无实际模块系统，占位）
	timeout: time.Duration, // --timeout（默认 1s）
}

// script 默认配置（gx script.NewConfig）。
script_new_config :: proc() -> Script_Config {
	return Script_Config{
		common = {dry_run = true},
		timeout       = time.Second,
	}
}

// parse_duration — Go time.ParseDuration 的实用子集：
// [-+]?([0-9]*(\.[0-9]*)?(ns|us|µs|ms|s|m|h))+。
// 与 Go 的差异：不支持 "+" 号（Go 支持但无实际用途），其余行为一致
// （无单位、单位非法、空串 → ok=false）。
parse_duration :: proc(s: string) -> (d: time.Duration, ok: bool) {
	if s == "" {
		return
	}
	i := 0
	neg := false
	if s[i] == '+' || s[i] == '-' {
		neg = s[i] == '-'
		i += 1
	}
	if i >= len(s) {
		return
	}
	total: time.Duration
	for i < len(s) {
		// 数字部分（整数或小数）
		start := i
		for i < len(s) && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.') {
			i += 1
		}
		if i == start {
			return // 缺数字
		}
		num, fok := strconv.parse_f64(s[start:i])
		if !fok {
			return
		}
		// 单位部分
		ustart := i
		for i < len(s) && !((s[i] >= '0' && s[i] <= '9') || s[i] == '.') {
			i += 1
		}
		unit_ns: time.Duration
		switch s[ustart:i] {
		case "ns":
			unit_ns = time.Nanosecond
		case "us", "µs", "μs":
			unit_ns = time.Microsecond
		case "ms":
			unit_ns = time.Millisecond
		case "s":
			unit_ns = time.Second
		case "m":
			unit_ns = time.Minute
		case "h":
			unit_ns = time.Hour
		case:
			return
		}
		total += time.Duration(f64(unit_ns) * num)
	}
	if neg {
		total = -total
	}
	return total, true
}

// script 选项表（gx script.getOptions，5 项，顺序一致）。
script_options :: proc() -> [5]Option {
	return {
		{short = "-e", long = "--expr", has_value = true, value_name = "EXPR",
			help = "inline expression (wrapped as __out := (EXPR))",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Script_Config)ctx
				c.expr = v
				return true
			}},
		{short = "-f", long = "--file", has_value = true, value_name = "FILE",
			help = "path to a script file",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Script_Config)ctx
				c.file = v
				return true
			}},
		{long = "--whole", help = "whole-file mode (awk-style): inject `content` instead of per-line",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Script_Config)ctx
				c.whole = true
				return true
			}},
		{long = "--unsafe", help = "enable ALL stdlib modules (os, rand, ...) — use with care",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Script_Config)ctx
				c.unsafe = true
				return true
			}},
		{long = "--timeout", has_value = true, value_name = "D",
			help = "per-execution timeout (e.g. 500ms, 2s); default 1s",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Script_Config)ctx
				d, ok := parse_duration(v)
				if !ok {
					return false
				}
				c.timeout = d
				return true
			}},
	}
}

// script 参数解析（gx script.ParseArgs：裸 ParseSimple）。
script_parse :: proc(argv: []string, c: ^Script_Config) -> bool {
	opts := script_options()
	return parse_simple(argv, &c.common, opts[:], script_print_usage)
}

// script 用法（gx script.printUsage）。
script_print_usage :: proc() {
	opts := script_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`script - Run a script over text (sed/awk style)

Usage: script (-e EXPR | -f FILE) [--whole] [--unsafe] [--timeout D] [FILE...]

Modes:
  line (default)  Per-line: injects line, lineno, filename. Result in __out.
  --whole          Per-file: injects content, filename. Result in __out.

Result convention (__out):
  string           emitted + newline
  undefined/false  line/file skipped (filtering)
  other            fmt.Sprint() then emitted + newline

Security:
  Default imports only a safe subset (text/math/fmt).
  --unsafe is accepted for compatibility (no module system in odd).

Examples:
  echo "hi" | odd script -e 'text.to_upper(line)'
  odd script -e 'lineno % 2 == 0 ? text.to_upper(line) : line' file
  odd script --whole -f agg.txt *.log
  odd script -e 'line + "!"' input.txt`, text)
}

// run_script — script 入口（迷你表达式引擎，见 expr.odin）。
// 退出码：0 有输出 / 1 无输出 / 2 参数、编译或运行期错误。
run_script :: proc(argv: []string) -> int {
	c := script_new_config()
	defer delete_dynamic_array(c.paths)
	if !script_parse(argv, &c) {
		return 2
	}
	if c.timeout <= 0 {
		c.timeout = time.Second // gx：非法/零值回落 1s
	}

	// 整段运行期的临时字符串（解析树、求值结果）都落 arena
	st := Script_Run{config = &c, base_alloc = context.allocator}
	mem.dynamic_arena_init(&st.arena)
	defer mem.dynamic_arena_destroy(&st.arena)
	context.allocator = mem.dynamic_arena_allocator(&st.arena)

	prog: Program
	if c.expr != "" {
		// gx 把 -e 包成 `__out := (EXPR)`
		lx := Lexer{src = c.expr}
		p := Parser{lx = &lx}
		advance(&p)
		expr, eok := parse_expression(&p)
		if !eok {
			fmt.fprintf(os.stderr, "script: compile: %s\n", p.err)
			return 2
		}
		if p.tok.kind != .EOF {
			fmt.fprintf(os.stderr, "script: compile: syntax error: trailing input at byte %d\n", p.tok.pos)
			return 2
		}
		assign := new(Stmt)
		assign.kind = .Assign
		assign.name = "__out"
		assign.expr = expr
		append(&prog.stmts, assign)
	} else if c.file == "" {
		fmt.fprintln(os.stderr, "script: script: exactly one of -e or -f is required")
		return 2
	} else {
		data, rerr := os.read_entire_file(c.file, context.allocator)
		if rerr != nil {
			fmt.fprintf(os.stderr, "script: script: read %s: open %s: no such file or directory\n", c.file, c.file)
			return 2
		}
		p2, perr := parse_program(string(data))
		if perr != "" {
			fmt.fprintf(os.stderr, "script: compile: %s\n", perr)
			return 2
		}
		prog = p2
	}

	// 输入路径：gx 把 Pattern（第一个位置参）也算路径，并丢掉默认的 "."
	paths := make([dynamic]string, 0, len(c.paths) + 1, context.allocator)
	defer delete_dynamic_array(paths)
	if c.pattern != "" {
		append(&paths, c.pattern)
	}
	for p in c.paths {
		if p == "." {
			continue
		}
		append(&paths, p)
	}
	if len(paths) == 0 {
		append(&paths, "-") // stdin
	}

	out: [dynamic]u8
	defer delete_dynamic_array(out)

	produced := 0
	run_err := ""
	if c.whole {
		produced, run_err = script_run_file_mode(&st, prog, paths[:], &out)
	} else {
		produced, run_err = script_run_line_mode(&st, prog, paths[:], &out)
	}
	if len(out) > 0 {
		os.write(os.stdout, out[:])
	}
	if run_err != "" {
		fmt.fprintf(os.stderr, "script: %s\n", run_err)
		return 2
	}
	return 0 if produced > 0 else 1
}

// Script_Run — 运行期状态（配置 + arena + 复用变量表）。
Script_Run :: struct {
	config:     ^Script_Config,
	arena:      mem.Dynamic_Arena,
	base_alloc: mem.Allocator,
}

// script_new_env — 每次迭代新建变量表（脚本里的变量不跨行残留，同 gx 的
// Compiled.Clone 语义）。
script_new_env :: proc(st: ^Script_Run) -> Env {
	return Env{vars = make(map[string]Val, mem.dynamic_arena_allocator(&st.arena))}
}

// script_emit_once — 求值一次并把结果按 __out 约定写入 out。
// 返回 (是否产出, 错误文本)。
script_emit_once :: proc(st: ^Script_Run, prog: Program, env: ^Env, out: ^[dynamic]u8, newline: bool) -> (bool, string) {
	if err := exec_program(env, prog); err != "" {
		return false, err
	}
	v, ok := env.vars["__out"]
	if !ok || v.kind == .Undef {
		return false, "" // undefined → 跳过
	}
	if v.kind == .Bool && !v.b {
		return false, "" // false → 跳过
	}
	append(out, ..transmute([]u8)val_display(v))
	if newline {
		append(out, '\n')
	}
	return true, ""
}

// script_run_line_mode — 逐行执行（sed 风格）。
script_run_line_mode :: proc(st: ^Script_Run, prog: Program, paths: []string, out: ^[dynamic]u8) -> (int, string) {
	data, name, ok := engine.read_all(paths, mem.dynamic_arena_allocator(&st.arena))
	if !ok {
		return 0, fmt.aprintf("open %s: no such file or directory", paths[0])
	}
	if name == "" || name == "-" {
		name = engine.STDIN_NAME
	}
	lines, lines_ok := scan_lines(data)
	if !lines_ok {
		return 0, "bufio.Scanner: token too long"
	}

	produced := 0
	errs: [dynamic]string
	defer delete_dynamic_array(errs)
	lineno := 0
	for line in lines {
		lineno += 1
		env := script_new_env(st)
		env.vars["line"] = val_str(line)
		env.vars["lineno"] = val_int(i64(lineno))
		env.vars["filename"] = val_str(name)
		emitted, rerr := script_emit_once(st, prog, &env, out, true)
		if rerr != "" {
			append(&errs, fmt.aprintf("line %d: %s", lineno, rerr))
			if len(errs) >= 10 {
				return produced, script_format_errors(errs[:], true)
			}
			continue
		}
		if emitted {
			produced += 1
		}
	}
	if len(errs) > 0 {
		return produced, script_format_errors(errs[:], false)
	}
	return produced, ""
}

// script_run_file_mode — 逐文件执行（awk 风格，输出不追加换行）。
script_run_file_mode :: proc(st: ^Script_Run, prog: Program, paths: []string, out: ^[dynamic]u8) -> (int, string) {
	produced := 0
	errs: [dynamic]string
	defer delete_dynamic_array(errs)
	for p in paths {
		content, name, ok := engine.read_all({p}, mem.dynamic_arena_allocator(&st.arena))
		if !ok {
			return produced, fmt.aprintf("open %s: no such file or directory", p)
		}
		if name == "" || name == "-" {
			name = engine.STDIN_NAME
		}
		env := script_new_env(st)
		env.vars["content"] = val_str(string(content))
		env.vars["filename"] = val_str(name)
		emitted, rerr := script_emit_once(st, prog, &env, out, false)
		if rerr != "" {
			append(&errs, fmt.aprintf("%s: %s", name, rerr))
			if len(errs) >= 10 {
				return produced, script_format_errors(errs[:], true)
			}
			continue
		}
		if emitted {
			produced += 1
		}
	}
	if len(errs) > 0 {
		return produced, script_format_errors(errs[:], false)
	}
	return produced, ""
}

// script_format_errors — gx 的错误汇总格式：
//   "%d runtime errors:\n  a\n  b"（超过 10 条时是 "%d+ runtime errors (showing first 10)"）
script_format_errors :: proc(errs: []string, truncated: bool) -> string {
	joined := strings.join(errs, "\n  ")
	if truncated {
		return fmt.aprintf("%d+ runtime errors (showing first 10):\n  %s", len(errs), joined)
	}
	return fmt.aprintf("%d runtime errors:\n  %s", len(errs), joined)
}
