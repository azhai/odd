package app

// ============================================================================
// cmd_replace.odin — replace 子命令（复刻 gx cmd/replace 的参数层）
//
// 职责：参数表 + parse + 用法 + 两种运行模式（搜索 / 替换）。
//
// 与 gx 的对齐点：
//   * 默认值同 find：ShowLineNum/Color = true、Workers = 1、DryRun = true
//   * 选项 = find 的 10 项 + -r/--replace + -x/--exec（共 11 项，顺序一致）
//   * parse 无 find 的 Replace 前插怪癖（replace 的第二位置参本就是替换串）
//   * 退出码：解析失败 / 正则非法 1；其余恒 0（gx main.runReplace 原样）
// ============================================================================

import "core:fmt"
import "core:os"
import "odd:engine"
import "odd:lib"
import "odd:search"

// replace 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Replace_Config :: struct {
	using common: Common_Config,
	show_line_num: bool, // -n / -N（默认 true）
	color:         bool, // --no-color 关闭
	workers:       int,  // -j（默认 1；0 = 全部核心）
	fixed_string:  bool, // -F
}

// replace 默认配置（gx replace.NewConfig）。
replace_new_config :: proc() -> Replace_Config {
	return Replace_Config{
		show_line_num = true,
		color         = true,
		workers       = 1,
		common = {dry_run = true},
	}
}

// replace 选项表（gx replace.getOptions，11 项，顺序一致）。
replace_options :: proc() -> [11]Option {
	return {
		{short = "-A", long = "--all", help = "Search all files (ignore .gitignore)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.ignore_gitignore = true
				return true
			}},
		{short = "-F", long = "--fixed-strings", help = "Treat pattern as literal string",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.fixed_string = true
				return true
			}},
		{short = "-g", long = "--glob", has_value = true, value_name = "PATTERN",
			help = "File glob pattern (e.g., \"*.go\")",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.file_pattern = v
				return true
			}},
		{short = "-i", long = "--ignore-case", help = "Case insensitive search",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.ignore_case = true
				return true
			}},
		{short = "-j", long = "--threads", has_value = true, value_name = "N", help = "Worker threads (0 = all cores, default 1)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				_ = parse_int_prefix(v, &c.workers)
				return true
			}},
		{short = "-n", long = "--line-number", help = "Show line numbers (default)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.show_line_num = true
				return true
			}},
		{short = "-N", long = "--no-line-number", help = "Hide line numbers",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.show_line_num = false
				return true
			}},
		{long = "--no-color", help = "Disable colored output",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.color = false
				return true
			}},
		{short = "-f", long = "--find", has_value = true, value_name = "PATTERN", help = "Pattern to find (regex supported)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.pattern = v
				return true
			}},
		{short = "-r", long = "--replace", has_value = true, value_name = "STRING", help = "Replacement string",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.replace = v
				c.replace_set = true
				return true
			}},
		{short = "-x", long = "--exec", help = "Execute replacement (default: dry-run)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Replace_Config)ctx
				c.dry_run = false
				return true
			}},
	}
}

// replace 参数解析（gx replace.ParseArgs：裸 ParseSimple）。
replace_parse :: proc(argv: []string, c: ^Replace_Config) -> bool {
	opts := replace_options()
	return parse_simple(argv, &c.common, opts[:], replace_print_usage)
}

// replace 用法（gx replace.printUsage）。
replace_print_usage :: proc() {
	opts := replace_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`replace - A fast search and replace tool inspired by ripgrep

Usage: replace [OPTIONS] PATTERN [REPLACE] [PATH...]

Options:
%s
Examples:
  replace "foo" "bar"                      Replace 'foo' with 'bar' (dry-run)
  replace "foo" "bar" -x                   Execute the replacement
  replace "old" "new" ./src                Search and replace in ./src
  replace -i "error" "warning"             Case insensitive replacement
  replace "\d+" "NUM" -g "*.log"           Replace numbers in log files`, text)
}

// ---------------------------------------------------------------------------
// 两种运行模式
//
//   * 搜索模式（未给 -r）：gx Searcher.Search → processor.Engine(skipBinary=true)，
//     输出与 find 完全一致（file:line: 高亮行），退出码恒 0。
//   * 替换模式（给了 -r，含 -r ""）：gx Searcher.Replace → 自己的 worker 池，
//     skipBinary=false（要重写二进制也不管），先打 [DRY-RUN]/[REPLACED] 行，
//     再逐行打印命中与 `-> 新行`。
// ---------------------------------------------------------------------------

// Replace_Ctx — processor handler 的用户数据（两种模式共用同一结构）。
Replace_Ctx :: struct {
	cfg: ^Replace_Config,
	re:  ^search.Regex,
}

// replace_search_handle_file — 搜索模式单文件处理（复刻 gx Searcher.ProcessFile）。
// gx 语义：os.Open 失败静默跳过；不检查 scanner.Err()（超长行静默截断）。
replace_search_handle_file :: proc(ctx: rawptr, entry: ^lib.File_Entry) {
	rc := cast(^Replace_Ctx)ctx
	data, err := os.read_entire_file(entry.path, context.allocator)
	if err != nil {
		return // 打不开 → 静默跳过（gx 同款）
	}
	defer delete(data, context.allocator)

	lines, _ := scan_lines(data) // gx 不检查 scanner.Err()
	defer delete_dynamic_array(lines)

	line_num := 0
	for line in lines {
		line_num += 1
		ms, found := search.regex_find_all(rc.re, transmute([]u8)line)
		if !found {
			continue
		}
		if len(ms) == 0 {
			search.regex_free_matches(rc.re, &ms)
			continue
		}
		print_match(rc.cfg.show_line_num, rc.cfg.color, entry.path, line_num, line, ms[:])
		search.regex_free_matches(rc.re, &ms)
	}
}

// replace_one_file — 替换模式单文件处理（复刻 gx Searcher.replaceFile）。
// 顺序严格对齐 gx：读失败静默跳过 → 无命中直接返回 → 干跑/落盘提示 →
// 再按行打印命中与 `-> 新行`（新旧行相同则不打印箭头）。
replace_one_file :: proc(ctx: rawptr, entry: ^lib.File_Entry) {
	rc := cast(^Replace_Ctx)ctx
	content, err := os.read_entire_file(entry.path, context.allocator)
	if err != nil {
		return // gx: 读失败直接 return
	}
	defer delete(content, context.allocator)

	// gx: matches := matcher.FindAll(content); if matches == nil { return }
	if !search.regex_matches(rc.re, content) {
		return
	}

	new_content, _ := search.regex_replace_all(rc.re, content, rc.cfg.replace)
	defer delete(new_content)

	if rc.cfg.dry_run {
		fmt.printf("\x1b[33m[DRY-RUN]\x1b[0m %s\n", entry.path)
	} else {
		// gx: os.WriteFile(path, newContent, 0644)
		werr := os.write_entire_file(entry.path, new_content, os.perm_number(0o644))
		if werr != nil {
			fmt.printf("\x1b[31mError writing %s: %v\x1b[0m\n", entry.path, werr)
		} else {
			fmt.printf("\x1b[32m[REPLACED]\x1b[0m %s\n", entry.path)
		}
	}

	// 逐行回放：命中行打印高亮 + 替换后的新行
	lines, _ := scan_lines(content)
	defer delete_dynamic_array(lines)

	line_num := 0
	for line in lines {
		line_num += 1
		ms, found := search.regex_find_all(rc.re, transmute([]u8)line)
		if !found {
			continue
		}
		if len(ms) == 0 {
			search.regex_free_matches(rc.re, &ms)
			continue
		}
		print_match(rc.cfg.show_line_num, rc.cfg.color, entry.path, line_num, line, ms[:])
		search.regex_free_matches(rc.re, &ms)

		new_line, _ := search.regex_replace_all(rc.re, transmute([]u8)line, rc.cfg.replace)
		if string(new_line) != line {
			fmt.printf("\x1b[36m-> %s\x1b[0m\n", string(new_line))
		}
		delete(new_line)
	}
}

// run_replace — replace 入口（完整实现）。
// 退出码：解析失败 / 正则非法 → 1（gx main.runReplace 原样）；其余恒 0。
run_replace :: proc(argv: []string) -> int {
	c := replace_new_config()
	defer delete_dynamic_array(c.paths)
	if !replace_parse(argv, &c) {
		return 1
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
		fmt.fprintf(os.stderr, "Error: invalid regex pattern: %s\n", c.pattern)
		return 1
	}

	// skip_binary：搜索模式跳过二进制（gx newEngine(true)），
	// 替换模式不跳过（gx Replace() 里 walkerConfig.SkipBinary = false）。
	wcfg := engine.Walker_Config{
		paths            = c.paths[:],
		file_pattern     = c.file_pattern,
		skip_binary      = !c.replace_set,
		ignore_gitignore = c.ignore_gitignore,
		allocator        = context.allocator,
	}
	res := engine.walk(wcfg)
	defer engine.walk_result_destroy(&res)

	rc := Replace_Ctx{cfg = &c, re = re}
	handler := engine.File_Handler{ctx = &rc, handle_file = replace_search_handle_file}
	if c.replace_set {
		handler.handle_file = replace_one_file
	}

	// gx 原样怪癖：Replace() 起的是 `for i := 0; i < Workers; i++` 个 goroutine，
	// 且**不**做 <=0 归一化——`-j 0` 在替换模式下等于零个 worker（什么都不做），
	// 与搜索模式（processor.New 把 <=0 归一成 NumCPU）不同。此处照抄。
	if c.replace_set && c.workers <= 0 {
		return 0
	}

	engine.run(res.entries[:], handler, c.workers)
	return 0
}
