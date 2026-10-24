package app

// ============================================================================
// cmd_list.odin — list 子命令（复刻 gx cmd/list 的参数层）
//
// 职责：参数表 + 独立解析器 + 用法 + 收集/过滤/排序/格式化全流程。
//
// 与 gx 的对齐点（含怪癖）：
//   * list **不**走 ParseSimple/ParseCommon，而是自己的 parseListArgs：
//     未注册的 "-xxx" 直接报错 "unknown option"（不像 find 那样当位置参）
//   * -h/--help 在任何位置都触发用法（全量扫描，先于解析）
//   * 空 argv → 用法 + false
//   * 校验型选项（-t/-s/--format）失败时先打印具体错误，再打一行
//     "Error: invalid value for <opt>"，共两行 stderr
//   * 默认值：TypeFilter "a"、Format "path"、MaxDepth 0（不限）
//   * 无路径 → ["."]
//   * **根路径自身不输出**（按 filepath.Abs 比对 rootSet）
//   * --format long 在 gx 里没有独立分支，与 show 同路径（打印 path 列）
//   * 时间列取 birthtime（darwin；gx 用 st_birthtimespec），零值/1970 前
//     回退为 mtime
//
// 已知偏差：
//   * 过滤表达式非法时 gx 透出 common.ParseSizeExpr/ParseTimeExpr 的具体
//     错误文案，本实现只有统一外壳（见 run_list 注释）
//   * Linux 上 gx 的 ctime 是 inode change time，Odin 的 creation_time 在
//     linux 上等于 mtime（stat_linux.odin），两者不同；darwin 一致
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "odd:engine"
import "odd:lib"

// list 配置（gx list.Config；注意不内嵌 Common_Config——list 无
// pattern/replace 概念，路径全部进 paths）。
List_Config :: struct {
	glob:        string, // -g
	size_expr:   string, // -S
	mtime_expr:  string, // -M
	ctime_expr:  string, // --ctime
	sort_field:  string, // -s
	reverse:     bool,   // -r
	type_filter: string, // -t（f/d/l/a，默认 a）
	format:      string, // --format（path/long/name/show，默认 path）
	max_depth:   int,    // -L（0 = 不限）
	paths:       [dynamic]string,
	show_fields: bool, // --show
}

// list 默认配置（gx list.NewConfig）。
list_new_config :: proc() -> List_Config {
	return List_Config{
		type_filter = "a",
		format      = "path",
	}
}

// list 选项表（gx list.getOptions，10 项，顺序一致）。
// 校验型选项失败时打印 gx 原文错误并返回 false。
list_options :: proc() -> [10]Option {
	return {
		{short = "-g", long = "--glob", has_value = true, value_name = "PATTERN", help = "File name glob pattern",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.glob = v
				return true
			}},
		{short = "-t", long = "--type", has_value = true, value_name = "f|d|l|a", help = "File type filter (default a)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				if v != "f" && v != "d" && v != "l" && v != "a" {
					fmt.fprintf(os.stderr, "Error: invalid type %q (must be f, d, l, or a)\n", v)
					return false
				}
				c := cast(^List_Config)ctx
				c.type_filter = v
				return true
			}},
		{short = "-S", long = "--size", has_value = true, value_name = "EXPR", help = "Size filter expression (e.g. >1M, <=100K)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.size_expr = v
				return true
			}},
		{short = "-M", long = "--mtime", has_value = true, value_name = "EXPR", help = "Modification time filter (e.g. <=1h, >=2025-01-01)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.mtime_expr = v
				return true
			}},
		{long = "--ctime", has_value = true, value_name = "EXPR", help = "Creation time filter (e.g. <=1d, >=2025-01-01)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.ctime_expr = v
				return true
			}},
		{short = "-s", long = "--sort", has_value = true, value_name = "FIELD", help = "Sort by field (name/size/mtime/ctime/path)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				switch v {
				case "name", "size", "mtime", "ctime", "path":
				case:
					fmt.fprintf(os.stderr, "Error: invalid sort field %q (must be name, size, mtime, ctime, or path)\n", v)
					return false
				}
				c := cast(^List_Config)ctx
				c.sort_field = v
				return true
			}},
		{short = "-r", long = "--reverse", help = "Reverse sort order",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.reverse = true
				return true
			}},
		{short = "-L", long = "--max-depth", has_value = true, value_name = "N", help = "Max recursion depth (0 = unlimited)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				_ = parse_int_prefix(v, &c.max_depth)
				return true
			}},
		{long = "--format", has_value = true, value_name = "path|long|name|show", help = "Output format (default path)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				if v != "path" && v != "long" && v != "name" && v != "show" {
					fmt.fprintf(os.stderr, "Error: invalid format %q (must be path, long, name, or show)\n", v)
					return false
				}
				c := cast(^List_Config)ctx
				c.format = v
				return true
			}},
		{long = "--show", help = "Show size, mtime, and ctime in fixed-width columns",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^List_Config)ctx
				c.show_fields = true
				return true
			}},
	}
}

// list_parse_list_args — 复刻 gx parseListArgs：逐参匹配选项表；带值选项
// 消费下一参；未注册的 "-" 前缀参 → 错误（gx 与 ParseCommon 的关键差异）；
// 其余为位置参。错误已打印具体原因，返回值仅供上层附一行 "Error: %v"。
list_parse_list_args :: proc(argv: []string, c: ^List_Config, opts: []Option) -> (positional: [dynamic]string, ok: bool) {
	for i := 0; i < len(argv); i += 1 {
		arg := argv[i]
		if opt := find_option(opts, arg); opt != nil {
			if opt.has_value {
				if i + 1 >= len(argv) {
					fmt.fprintf(os.stderr, "Error: %s requires a value\n", arg)
					return
				}
				if !opt.handler(argv[i + 1], rawptr(c)) {
					fmt.fprintf(os.stderr, "Error: invalid value for %s\n", arg)
					return
				}
				i += 1
			} else {
				if !opt.handler("", rawptr(c)) {
					fmt.fprintf(os.stderr, "Error: invalid option %s\n", arg)
					return
				}
			}
		} else if strings.has_prefix(arg, "-") {
			fmt.fprintf(os.stderr, "Error: unknown option %s\n", arg)
			return
		} else {
			append(&positional, arg)
		}
	}
	ok = true
	return
}

// list 参数解析（gx list.ParseArgs）。
list_parse :: proc(argv: []string, c: ^List_Config) -> bool {
	opts := list_options()
	if len(argv) == 0 {
		list_print_usage()
		return false
	}
	for arg in argv {
		if arg == "-h" || arg == "--help" {
			list_print_usage()
			return false
		}
	}

	positional, ok := list_parse_list_args(argv, c, opts[:])
	if !ok {
		delete_dynamic_array(positional)
		return false
	}
	for arg in positional {
		append(&c.paths, arg)
	}
	delete_dynamic_array(positional)

	if len(c.paths) == 0 {
		append(&c.paths, ".")
	}
	return true
}

// list 用法（gx list.printUsage）。
list_print_usage :: proc() {
	opts := list_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`list - List files and directories with filters (like ls)

Usage: list [OPTIONS] [PATH...]

Options:
%s
Examples:
  list ./src
  list -g "*.go" --size ">1K" --mtime "<=1d" ./src
  list --format long --sort size --reverse ./data
  list --type d --max-depth 1 .`, text)
}

// ---------------------------------------------------------------------------
// 运行期
// ---------------------------------------------------------------------------

// List_Entry — 复刻 gx list.Entry（去掉 Mode：gx 的 formatMode 是死代码）。
List_Entry :: struct {
	path:           string,
	name:           string,
	size:           i64,
	mod_time:       time.Time,
	change_time:    time.Time,
	is_dir:         bool,
	is_symlink:     bool,
	symlink_target: string, // 空串 = 读链接失败（打印 " -> [error]"）
}

// List_Ctx — 一次 list 运行的状态；所有瞬态字符串走 arena。
List_Ctx :: struct {
	config:        ^List_Config,
	size_filter:   lib.Size_Filter,
	has_size:      bool,
	mtime_filter:  lib.Time_Filter,
	has_mtime:     bool,
	ctime_filter:  lib.Time_Filter,
	has_ctime:     bool,
	entries:       [dynamic]List_Entry,
	arena:         mem.Dynamic_Arena,
	base_alloc:    mem.Allocator, // 切 context.allocator 之前保存的分配器
}

list_alloc :: proc(st: ^List_Ctx) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&st.arena)
}

list_should_show_size :: proc(c: ^List_Config) -> bool {
	return c.show_fields || c.size_expr != ""
}

list_should_show_mtime :: proc(c: ^List_Config) -> bool {
	return c.show_fields || c.mtime_expr != ""
}

list_should_show_ctime :: proc(c: ^List_Config) -> bool {
	return c.show_fields || c.ctime_expr != ""
}

// list_change_time — 复刻 gx getChangeTime：darwin 取 birthtime，
// 零值或 1970 年前 → 回退 mtime。（walker 的 lstat 已带 birthtime，
// 不再额外 stat，省一次系统调用。）
list_change_time :: proc(e: ^lib.File_Entry) -> time.Time {
	ct := e.creation_time
	if lib.time_is_zero(ct) || time.year(ct) <= 1970 {
		return e.mod_time
	}
	return ct
}

// list_to_entry — 复刻 gx toEntry（含 readlink）。
list_to_entry :: proc(st: ^List_Ctx, e: ^lib.File_Entry) -> List_Entry {
	out := List_Entry{
		path        = e.path,
		name        = e.name,
		size        = e.size,
		mod_time    = e.mod_time,
		change_time = list_change_time(e),
		is_dir      = e.is_dir,
		is_symlink  = e.is_symlink,
	}
	if out.is_symlink {
		if target, err := os.read_link(e.path, list_alloc(st)); err == nil {
			out.symlink_target = target
		}
	}
	return out
}

// list_match — 复刻 gx matchEntry：类型 → 目录 glob（walk 已过滤文件）→
// 大小 → mtime → ctime。
list_match :: proc(st: ^List_Ctx, e: List_Entry) -> bool {
	c := st.config
	if c.type_filter != "a" {
		switch c.type_filter {
		case "f":
			if e.is_dir || e.is_symlink {
				return false
			}
		case "d":
			if !e.is_dir {
				return false
			}
		case "l":
			if !e.is_symlink {
				return false
			}
		}
	}

	// 目录走 walker 的 include_dir 通道，不经过文件 glob；这里补一次
	if c.glob != "" && e.is_dir {
		matched, merr := filepath.match(c.glob, e.name)
		if merr != nil || !matched {
			return false
		}
	}
	if st.has_size && !lib.size_match(st.size_filter, e.size) {
		return false
	}
	if st.has_mtime && !lib.time_match(st.mtime_filter, e.mod_time) {
		return false
	}
	if st.has_ctime && !lib.time_match(st.ctime_filter, e.change_time) {
		return false
	}
	return true
}

// list_format_path_with_marker — 复刻 gx formatPathWithMarker：
// 目录补 "/"，符号链接补 " -> target"（目标本身是目录再加 "/"）。
list_format_path_with_marker :: proc(st: ^List_Ctx, e: List_Entry) -> string {
	path := e.path
	if e.is_dir {
		path = fmt.aprintf("%s/", path, allocator = list_alloc(st))
	}
	if e.is_symlink {
		if e.symlink_target == "" {
			path = fmt.aprintf("%s -> [error]", path, allocator = list_alloc(st))
		} else {
			target := e.symlink_target
			// gx: os.Stat(Join(Dir(e.Path), target)) → 是目录则补 "/"
			if dir, ok := engine.go_dir(e.path, list_alloc(st)); ok {
				if joined, jerr := filepath.join({dir, target}, list_alloc(st)); jerr == nil {
					if fi, serr := os.stat(joined, list_alloc(st)); serr == nil {
						if fi.type == .Directory {
							target = fmt.aprintf("%s/", target, allocator = list_alloc(st))
						}
					}
				}
			}
			path = fmt.aprintf("%s -> %s", path, target, allocator = list_alloc(st))
		}
	}
	return path
}

// list_calculate_column_widths — 复刻 gx calculateColumnWidths（path 列
// 至少 40，最长不超 120）。
list_calculate_column_widths :: proc(st: ^List_Ctx) -> lib.Column_Widths {
	widths := lib.default_column_widths()
	max_path_len := 0
	for e in st.entries {
		n := len(list_format_path_with_marker(st, e))
		if n > max_path_len {
			max_path_len = n
		}
	}
	if max_path_len > widths.path {
		widths.path = min(max_path_len, 120)
	}
	return widths
}

// list_print_entry — 复刻 gx printEntry（name / 纯 path / 列式三种形态）。
list_print_entry :: proc(st: ^List_Ctx, e: List_Entry, widths: lib.Column_Widths) {
	c := st.config
	if c.format == "name" {
		fmt.println(e.name)
		return
	}

	path := list_format_path_with_marker(st, e)
	show_size := list_should_show_size(c)
	show_mtime := list_should_show_mtime(c)
	show_ctime := list_should_show_ctime(c)
	if c.format == "path" && !show_size && !show_mtime && !show_ctime {
		fmt.println(path)
		return
	}

	parts: [dynamic]string
	defer delete_dynamic_array(parts)
	if show_size {
		append(&parts, lib.format_fixed_width(lib.format_size(e.size), widths.size, true))
	}
	if show_mtime {
		append(&parts, lib.format_fixed_width(lib.format_time(e.mod_time), widths.time, false))
	}
	if show_ctime {
		append(&parts, lib.format_fixed_width(lib.format_time(e.change_time), widths.time, false))
	}
	append(&parts, lib.format_fixed_width(path, widths.path, false))
	fmt.println(strings.join(parts[:], " "))
}

// 排序上下文。**为什么是包级变量**：core:slice 的 stable_sort_by 没有
// user_data 版本，比较器只能看见两个元素——排序键（字段 + 是否倒序）只能
// 从这里读。list 的排序是单线程的，不存在竞态；用完即清零。
List_Sort_Key :: struct {
	field:   string,
	reverse: bool,
}

LIST_SORT_KEY: List_Sort_Key

// 复刻 gx sortEntries 的比较器（含 reverse 时 `less = !less` 的原样写法）。
list_entry_less :: proc(a, b: List_Entry) -> bool {
	less := false
	switch LIST_SORT_KEY.field {
	case "name":
		less = a.name < b.name
	case "size":
		less = a.size < b.size
	case "mtime":
		less = lib.time_before(a.mod_time, b.mod_time)
	case "ctime":
		less = lib.time_before(a.change_time, b.change_time)
	case "path":
		less = a.path < b.path
	}
	if LIST_SORT_KEY.reverse {
		less = !less // gx 原样：并列项在倒序时会相对位置反转
	}
	return less
}

// list_sort_entries — 复刻 gx sortEntries（stable，五个字段 + reverse 取反）。
//
// 早前这里是插入排序（O(n²)）：条目数上千就明显吃力。换成 core:slice 的
// 稳定排序后是 O(n log n)。两条对外行为的保险差分页明确守着：
//   * "sort 并列 size/mtime"（正序 + 倒序）——夹具里有三条 size 与 mtime
//     完全相同的记录，用来锁定并列时的相对顺序。
list_sort_entries :: proc(st: ^List_Ctx) {
	c := st.config
	switch c.sort_field {
	case "name", "size", "mtime", "ctime", "path":
		// 已知字段才排序
	case:
		return // 未知字段：gx 也是不排序（实际在参数层就已被拦下）
	}
	LIST_SORT_KEY = {field = c.sort_field, reverse = c.reverse}
	defer LIST_SORT_KEY = {}
	slice.stable_sort_by(st.entries[:], list_entry_less)
}

// run_list — list 入口（完整实现）。
// 退出码：0 有条目 / 1 无条目 / 2 参数或表达式错误（gx main.runList 原样）。
run_list :: proc(argv: []string) -> int {
	c := list_new_config()
	defer delete_dynamic_array(c.paths)
	if !list_parse(argv, &c) {
		return 2
	}

	st := List_Ctx{config = &c, base_alloc = context.allocator}
	mem.dynamic_arena_init(&st.arena)
	// 整段运行期的临时字符串（格式化列、map 键、readlink 结果）都落 arena：
	// 直接把 context.allocator 切过去，各 lib 助手就不必逐处传 allocator。
	context.allocator = list_alloc(&st)
	defer {
		mem.dynamic_arena_destroy(&st.arena)
		delete_dynamic_array(st.entries)
	}

	// 过滤器（gx NewLister）；错误文案只保留外壳，细节见文件头"已知偏差"
	now := time.now()
	if c.size_expr != "" {
		f, ok := lib.parse_size_expr(c.size_expr)
		if !ok {
			fmt.fprintf(os.stderr, "Error: invalid size expression: %s\n", c.size_expr)
			return 2
		}
		st.size_filter, st.has_size = f, true
	}
	if c.mtime_expr != "" {
		f, ok := lib.parse_time_expr(c.mtime_expr, now)
		if !ok {
			fmt.fprintf(os.stderr, "Error: invalid mtime expression: %s\n", c.mtime_expr)
			return 2
		}
		st.mtime_filter, st.has_mtime = f, true
	}
	if c.ctime_expr != "" {
		f, ok := lib.parse_time_expr(c.ctime_expr, now)
		if !ok {
			fmt.fprintf(os.stderr, "Error: invalid ctime expression: %s\n", c.ctime_expr)
			return 2
		}
		st.ctime_filter, st.has_ctime = f, true
	}

	// walker：目录/符号链接是否产出取决于 -t；glob 走 FilePattern
	wcfg := engine.Walker_Config{
		paths           = c.paths[:],
		file_pattern    = c.glob,
		include_dir     = c.type_filter == "d" || c.type_filter == "a",
		include_symlink = c.type_filter == "l" || c.type_filter == "a",
		max_depth       = c.max_depth,
		allocator       = st.base_alloc,
	}
	res := engine.walk(wcfg)
	defer engine.walk_result_destroy(&res)

	// 根路径自身不输出（gx：按 Abs 比对）
	root_set := make(map[string]bool, list_alloc(&st))
	for p in c.paths {
		if abs, aerr := filepath.abs(p, list_alloc(&st)); aerr == nil {
			root_set[abs] = true
		}
	}
	for &e in res.entries {
		if abs, aerr := filepath.abs(e.path, list_alloc(&st)); aerr == nil {
			if _, is_root := root_set[abs]; is_root {
				continue
			}
		}
		entry := list_to_entry(&st, &e)
		if list_match(&st, entry) {
			append(&st.entries, entry)
		}
	}

	if c.sort_field != "" {
		list_sort_entries(&st)
	}

	if len(st.entries) == 0 {
		return 1
	}

	widths := list_calculate_column_widths(&st)
	for e in st.entries {
		list_print_entry(&st, e, widths)
	}
	return 0
}
