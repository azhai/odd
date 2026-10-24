package app

// ============================================================================
// cmd_find.odin — find 子命令（复刻 gx cmd/find）
//
// 职责：参数表 + parse + 用法；run 在任务 #6 与 search/engine 接通后补齐。
//
// 与 gx 的对齐点：
//   * 默认值：ShowLineNum/Color = true、Workers = 1、DryRun = true
//     （find 不写盘，DryRun 只是占位；-j 0 = 全部核心）
//   * ParseArgs 怪癖：ParseSimple 的 2 参智能模式会把第二参塞进 Replace
//     （经 ParseCommon 的位置参链），find 再把它前插回 Paths 并清空
//     Replace——净效果是 `find -i foo bar` = pattern=foo, paths=[bar, "."]。
//     注意仅当 Replace != "" 时才前插（-r "" 不触发，gx 原样）。
// ============================================================================

import "core:fmt"
import "core:os"
import "odd:engine"
import "odd:lib"
import "odd:search"

// find 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Find_Config :: struct {
	using common: Common_Config,
	show_line_num: bool, // -n / -N（默认 true）
	color:         bool, // --no-color 关闭
	workers:       int,  // -j（默认 1；0 = 全部核心）
	fixed_string:  bool, // -F
	files_only:    bool, // -l
}

// find 默认配置（gx find.NewConfig）。
find_new_config :: proc() -> Find_Config {
	return Find_Config{
		show_line_num = true,
		color         = true,
		workers       = 1,
		common = {dry_run = true},
	}
}

// find 选项表（gx find.getOptions，10 项，顺序一致）。
find_options :: proc() -> [10]Option {
	return {
		{short = "-A", long = "--all", help = "Search all files (ignore .gitignore)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.ignore_gitignore = true
				return true
			}},
		{short = "-F", long = "--fixed-strings", help = "Treat pattern as literal string",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.fixed_string = true
				return true
			}},
		{short = "-g", long = "--glob", has_value = true, value_name = "PATTERN", help = "File glob pattern",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.file_pattern = v
				return true
			}},
		{short = "-i", long = "--ignore-case", help = "Case insensitive search",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.ignore_case = true
				return true
			}},
		{short = "-j", long = "--threads", has_value = true, value_name = "N", help = "Worker threads (0 = all cores, default 1)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				_ = parse_int_prefix(v, &c.workers) // Sscanf 语义：垃圾输入保持原值
				return true
			}},
		{short = "-l", long = "--files-with-matches", help = "Print only file paths with matches",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.files_only = true
				return true
			}},
		{short = "-n", long = "--line-number", help = "Show line numbers (default)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.show_line_num = true
				return true
			}},
		{short = "-N", long = "--no-line-number", help = "Hide line numbers",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.show_line_num = false
				return true
			}},
		{long = "--no-color", help = "Disable colored output",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.color = false
				return true
			}},
		{short = "-f", long = "--find", has_value = true, value_name = "PATTERN", help = "Pattern to find (regex supported)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Find_Config)ctx
				c.pattern = v
				return true
			}},
	}
}

// find 参数解析（gx find.ParseArgs，含 Replace → Paths 前插怪癖）。
find_parse :: proc(argv: []string, c: ^Find_Config) -> bool {
	opts := find_options()
	if !parse_simple(argv, &c.common, opts[:], find_print_usage) {
		return false
	}
	if c.replace != "" {
		// 前插：paths = [replace, ...paths]（gx 原样；inject_at 原地完成）
		inject_at_elem(&c.paths, 0, c.replace)
		c.replace = ""
		c.replace_set = false
	}
	return true
}

// find 用法（gx find.printUsage）。
find_print_usage :: proc() {
	opts := find_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`find - A fast file content search tool inspired by ripgrep

Usage: find [OPTIONS] PATTERN [PATH...]

Options:
%s
Examples:
  find "TODO" ./src
  find -i "error" -g "*.go"`, text)
}

// find 处理上下文（processor handler 的 user-data）。
// re 由主线程编译（其 allocator 即编译期 context.allocator）；
// find_all_impl 的一切匹配分配都走 re.allocator 或动态数组自记录的
// 分配器，因此工作线程里匹配/释放是分配器安全的。
Find_Ctx :: struct {
	cfg:     ^Find_Config,
	re:      ^search.Regex,
	had_hit: bool,
}

// print_match — 复刻 gx printMatch：前缀 path:linenum:（或 path:），
// 随后是带红色高亮（\x1b[31m..\x1b[0m）或原样的整行。
// 注意 gx **不**检测 TTY——管道输出同样带色（已实测确认）。
// find 与 replace 共用（gx 里两边各有一份同款 printMatch）。
print_match :: proc(show_line_num, color: bool, path: string, line_num: int, line: string, ms: []search.Match) {
	if show_line_num {
		fmt.printf("%s:%d:", path, line_num)
	} else {
		fmt.printf("%s:", path)
	}
	if color {
		last_end := 0
		for m in ms {
			fmt.printf("%s\x1b[31m%s\x1b[0m", line[last_end:m.start], line[m.start:m.end])
			last_end = m.end
		}
		fmt.println(line[last_end:])
	} else {
		fmt.println(line)
	}
}

// find_handle_file — 单文件处理（复刻 gx Searcher.ProcessFile + printMatch）。
// gx 语义：os.Open 失败静默跳过；-l 时首个命中行即打印路径并返回；
// 不检查 scanner.Err()（超长行静默截断）。
find_handle_file :: proc(ctx: rawptr, entry: ^lib.File_Entry) {
	fc := cast(^Find_Ctx)ctx
	data, err := os.read_entire_file(entry.path, context.allocator)
	if err != nil {
		return // 打不开 → 静默跳过（gx 同款）
	}
	defer delete(data, context.allocator)

	lines, _ := scan_lines(data) // find 无视 token-too-long
	defer delete_dynamic_array(lines)

	line_num := 0
	for line in lines {
		line_num += 1
		ms, found := search.regex_find_all(fc.re, transmute([]u8)line)
		if !found {
			continue
		}
		if len(ms) == 0 {
			search.regex_free_matches(fc.re, &ms)
			continue
		}
		fc.had_hit = true
		if fc.cfg.files_only {
			fmt.println(entry.path)
			search.regex_free_matches(fc.re, &ms)
			return // 一个文件只打印一次路径
		}
		print_match(fc.cfg.show_line_num, fc.cfg.color, entry.path, line_num, line, ms[:])
		search.regex_free_matches(fc.re, &ms)
	}
}

// run_find — find 入口（完整实现）。
// 退出码：0 有命中 / 1 无命中 / 2 参数错误或正则编译失败。
run_find :: proc(argv: []string) -> int {
	c := find_new_config()
	defer delete_dynamic_array(c.paths)
	if !find_parse(argv, &c) {
		return 2
	}

	// FixedString → QuoteMeta（gx：regexp.QuoteMeta 后再编译）
	// 注意：defer 在 Odin 里是**块作用域**（离开 if 块即执行），
	// 不能写在 if 内部——否则 quoted 会在 compile 之前被释放。
	pattern := c.pattern
	quoted: string
	if c.fixed_string {
		quoted = search.regex_quote_meta(pattern)
		pattern = quoted
	}
	defer {
		if quoted != "" {
			delete(quoted)
		}
	}
	re, ok := search.regex_compile(pattern, c.ignore_case)
	defer search.regex_destroy(re)
	if !ok {
		// gx: Error: invalid regex pattern: <Go 原文>；本引擎无等价细节文本
		fmt.fprintf(os.stderr, "Error: invalid regex pattern: %s\n", c.pattern)
		return 2
	}

	wcfg := engine.Walker_Config{
		paths            = c.paths[:],
		file_pattern     = c.file_pattern,
		skip_binary      = true, // gx find 硬编码
		ignore_gitignore = c.ignore_gitignore,
		allocator        = context.allocator,
	}
	res := engine.walk(wcfg)
	defer engine.walk_result_destroy(&res)

	fc := Find_Ctx{cfg = &c, re = re}
	handler := engine.File_Handler{ctx = &fc, handle_file = find_handle_file}
	engine.run(res.entries[:], handler, c.workers)

	return 0 if fc.had_hit else 1 // 无命中 → grep 约定退出 1
}
