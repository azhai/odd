package app

// ============================================================================
// cmd_rename.odin — rename 子命令（复刻 gx cmd/rename 的参数层）
//
// 职责：参数表 + parse + 用法 + 收集/冲突检测/预览/执行全流程。
//
// 与 gx 的对齐点：
//   * 默认值：DryRun = true（-x 才真正改名）
//   * 8 个选项：-d/-F/-f/-g/-i/-r/-x/--force（顺序一致）
//   * parse 为裸 ParseSimple（无 find 的前插怪癖）
//   * 退出码：0 成功 / 1 无匹配 / 2 参数错误或存在冲突且未 --force
//   * 冲突判定：同目录下新旧路径**小写后**相同则不算冲突；否则 os.Stat 成功
//     即冲突（大小写不敏感文件系统上 a→A 不误判）
//
// 已知偏差：gx 用 sort.Slice（不稳定）按 Original 长度降序排，长度相同的项
// 顺序未定义；这里用稳定排序（同长度保持 walk 顺序），输出更可复现。
// ============================================================================

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "odd:engine"
import "odd:lib"
import "odd:search"

// rename 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Rename_Config :: struct {
	using common: Common_Config,
	force:       bool, // --force：冲突也继续
	include_dir: bool, // -d：目录也参与重命名
	fixed_string: bool, // -F
}

// rename 默认配置（gx rename.NewConfig）。
rename_new_config :: proc() -> Rename_Config {
	return Rename_Config{
		common = {dry_run = true},
	}
}

// rename 选项表（gx rename.getOptions，8 项，顺序一致）。
rename_options :: proc() -> [8]Option {
	return {
		{short = "-d", long = "--include-dir", help = "Include directories",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.include_dir = true
				return true
			}},
		{short = "-F", long = "--fixed-strings", help = "Treat pattern as literal string",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.fixed_string = true
				return true
			}},
		{short = "-f", long = "--find", has_value = true, value_name = "PATTERN", help = "Pattern to find (regex supported)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.pattern = v
				return true
			}},
		{short = "-g", long = "--glob", has_value = true, value_name = "PATTERN", help = "File glob pattern (e.g., \"*.jpg\")",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.file_pattern = v
				return true
			}},
		{short = "-i", long = "--ignore-case", help = "Case insensitive matching",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.ignore_case = true
				return true
			}},
		{short = "-r", long = "--replace", has_value = true, value_name = "STRING", help = "Replacement string",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.replace = v
				c.replace_set = true
				return true
			}},
		{short = "-x", long = "--exec", help = "Execute the rename (default: dry-run)",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.dry_run = false
				return true
			}},
		{long = "--force", help = "Force rename even with conflicts",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Rename_Config)ctx
				c.force = true
				return true
			}},
	}
}

// rename 参数解析（gx rename.ParseArgs：裸 ParseSimple）。
rename_parse :: proc(argv: []string, c: ^Rename_Config) -> bool {
	opts := rename_options()
	return parse_simple(argv, &c.common, opts[:], rename_print_usage)
}

// rename 用法（gx rename.printUsage）。
rename_print_usage :: proc() {
	opts := rename_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`rename - A batch file renaming tool inspired by f2

Usage: rename [OPTIONS] FIND [REPLACE] [PATH...]

Options:
%s
Examples:
  rename "foo" "bar"                      Replace 'foo' with 'bar'
  rename "\.txt$" ".md"                   Change .txt to .md extension
  rename "(\d+)" "prefix_$1" -x           Add prefix to numbers
  rename -i "IMG" "img" -g "*.jpg"        Case conversion for jpg files
  rename "^" "2024_" -x                   Add date prefix to all files`, text)
}

// Rename_Op — 一条待执行的重命名操作（复刻 gx RenameOp，去掉 Error 字段：
// gx 只写不读，实际错误在 Execute 里当场打印）。
Rename_Op :: struct {
	original:  string, // 原基名
	new_name:  string, // 新基名
	base_dir:  string, // 所在目录（Go filepath.Dir 语义）
	conflict:  bool,
}

// rename_ctx — 一次 rename 运行的全部状态。
// 所有瞬态字符串（新名、join 结果、小写键）都落在 arena 上，
// run_rename 结束时一次 destroy，不做逐个 delete。
Rename_Ctx :: struct {
	config: ^Rename_Config,
	re:     ^search.Regex,
	ops:    [dynamic]Rename_Op,
	arena:  mem.Dynamic_Arena,
}

// rename_join — Go filepath.Join 语义（Odin 的 join 已自带 Clean，
// "." 分量会被吃掉：join(".", "a.txt") == "a.txt"）。
rename_join :: proc(st: ^Rename_Ctx, dir, name: string) -> string {
	joined, err := filepath.join({dir, name}, mem.dynamic_arena_allocator(&st.arena))
	if err != nil {
		return name
	}
	return joined
}

// rename_collect — 复刻 gx Renamer.CollectFiles：
// walk（IncludeDir 由 -d 决定、SkipBinary=false、**不**忽略 .gitignore）→
// 基名匹配 → 生成新名 → 记录 base_dir。
rename_collect :: proc(st: ^Rename_Ctx) {
	c := st.config
	wcfg := engine.Walker_Config{
		paths        = c.paths[:],
		file_pattern = c.file_pattern,
		include_dir  = c.include_dir,
		skip_binary  = false, // gx rename 读所有文件
		allocator    = context.allocator,
	}
	res := engine.walk(wcfg)
	defer engine.walk_result_destroy(&res)

	for e in res.entries {
		if !search.regex_matches(st.re, transmute([]u8)e.name) {
			continue
		}
		nb, _ := search.regex_replace_all(st.re, transmute([]u8)e.name, c.replace)
		defer delete(nb)
		new_name := string(nb) // 借用 nb；下面 clone 进 arena 后再释放
		keep := new_name != e.name && new_name != ""
		if !keep {
			continue
		}
		dir, ok := engine.go_dir(e.path, mem.dynamic_arena_allocator(&st.arena))
		if !ok {
			continue
		}
		owned, _ := strings.clone(new_name, mem.dynamic_arena_allocator(&st.arena))
		append(&st.ops, Rename_Op{original = e.name, new_name = owned, base_dir = dir})
	}

	// 按原基名长度降序（稳定）：先改长名，避免 a→aa 这类前缀扩张互相覆盖
	for i := 1; i < len(st.ops); i += 1 {
		j := i
		for j > 0 && len(st.ops[j].original) > len(st.ops[j - 1].original) {
			st.ops[j], st.ops[j - 1] = st.ops[j - 1], st.ops[j]
			j -= 1
		}
	}
}

// rename_detect_conflicts — 复刻 gx Renamer.DetectConflicts。
rename_detect_conflicts :: proc(st: ^Rename_Ctx) {
	falloc := mem.dynamic_arena_allocator(&st.arena)
	new_paths := make(map[string]int, falloc)
	for i := 0; i < len(st.ops); i += 1 {
		op := &st.ops[i]
		new_path := rename_join(st, op.base_dir, op.new_name)
		key := strings.to_lower(new_path, falloc)

		if first, exists := new_paths[key]; exists {
			op.conflict = true
			st.ops[first].conflict = true
		} else {
			new_paths[key] = i
		}

		// 目标已存在 → 冲突（大小写不同视为同一路径，跳过）
		original_path := rename_join(st, op.base_dir, op.original)
		if key != strings.to_lower(original_path, falloc) {
			if os.exists(new_path) {
				op.conflict = true
			}
		}
	}
}

// rename_print_preview — 复刻 gx Renamer.PrintPreview（含全部 ANSI 色码与空行）。
rename_print_preview :: proc(st: ^Rename_Ctx) {
	if len(st.ops) == 0 {
		fmt.println("No files to rename")
		return
	}
	fmt.printf("\n%d file(s) to rename:\n\n", len(st.ops))

	conflict_count := 0
	for op in st.ops {
		original_path := rename_join(st, op.base_dir, op.original)
		new_path := rename_join(st, op.base_dir, op.new_name)
		if op.conflict {
			conflict_count += 1
			fmt.printf("  \x1b[33mCONFLICT\x1b[0m: %s\n", original_path)
			fmt.printf("           -> \x1b[31m%s\x1b[0m\n", new_path)
		} else {
			fmt.printf("  \x1b[32m%s\x1b[0m\n", original_path)
			fmt.printf("  -> \x1b[36m%s\x1b[0m\n", new_path)
		}
	}

	if conflict_count > 0 {
		fmt.printf("\n\x1b[33m%d conflict(s) detected\x1b[0m\n", conflict_count)
		if !st.config.force {
			fmt.println("Use --force to proceed with conflicts")
		}
	}

	if st.config.dry_run {
		fmt.println("\n\x1b[33mDry run - no changes made\x1b[0m")
		fmt.println("Use -x or --exec to apply changes")
	}
}

// rename_execute — 复刻 gx Renamer.Execute。
// 返回 false 表示存在未解决的冲突（调用方按 exit 2 处理）。
rename_execute :: proc(st: ^Rename_Ctx) -> bool {
	if st.config.dry_run {
		return true
	}

	conflict_count := 0
	for op in st.ops {
		if op.conflict {
			conflict_count += 1
		}
	}
	if conflict_count > 0 && !st.config.force {
		fmt.fprintln(os.stderr, "\x1b[31mError: conflicts detected, use --force to proceed\x1b[0m")
		return false
	}

	executed := 0
	for op in st.ops {
		if op.conflict && !st.config.force {
			continue
		}
		old_path := rename_join(st, op.base_dir, op.original)
		new_path := rename_join(st, op.base_dir, op.new_name)
		if err := os.rename(old_path, new_path); err != nil {
			fmt.printf("\x1b[31mError: %s -> %s: %v\x1b[0m\n", old_path, new_path, err)
			continue
		}
		executed += 1
	}
	fmt.printf("\n\x1b[32mSuccessfully renamed %d file(s)\x1b[0m\n", executed)
	return true
}

// run_rename — rename 入口（完整实现）。
// 退出码：0 成功 / 1 无匹配 / 2 参数错误、正则非法或冲突未 --force。
run_rename :: proc(argv: []string) -> int {
	c := rename_new_config()
	defer delete_dynamic_array(c.paths)
	if !rename_parse(argv, &c) {
		return 2
	}

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
		return 2
	}

	st := Rename_Ctx{config = &c, re = re}
	mem.dynamic_arena_init(&st.arena)
	defer {
		mem.dynamic_arena_destroy(&st.arena)
		delete_dynamic_array(st.ops)
	}

	rename_collect(&st)
	rename_detect_conflicts(&st)
	rename_print_preview(&st)

	if !rename_execute(&st) {
		return 2
	}
	if len(st.ops) == 0 {
		return 1 // 无匹配 → exit 1（gx spec 4.2）
	}
	return 0
}
