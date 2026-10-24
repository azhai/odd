package app

// ============================================================================
// cmd_cut.odin — cut 子命令（复刻 gx cmd/cut，POSIX cut 的 -f 子集）
//
// 职责：从分隔文本中提取字段。stdin/stdout 过滤器：读一个文件（无路径或
//       "-" 时读 stdin），按分隔符切行，输出选中字段（按输出分隔符拼接）。
//
// 与 gx 的对齐点（含怪癖）：
//   * 字段 1-based；`N-` 开放到行尾；`-M` = 1..M；hi=-1 或越界夹到行尾
//   * `-d` 支持 \t \n \\ 转义；空 -d 回落 tab
//   * 行按 \n 切、剥行尾 \r（bufio.Scanner ScanLines 语义）
//   * 无分隔符的行：-s 跳过，否则原样输出
//   * 第一个位置参（ParseCommon 放进 pattern）作为输入文件；无则 stdin。
//     第二个位置参起被静默忽略（gx 原样：Paths 被整体替换为 [Pattern]）
//   * 退出码：0 成功 / 2 参数或 IO 错误
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "odd:engine"

// 字段区间：0-based 闭区间；hi == -1 表示开放（到行尾，`N-` 形态）。
Field_Range :: struct {
	lo: int,
	hi: int,
}

// 行扫描上限（复刻 gx 的 scanner.Buffer(..., 1024*1024)）。
SCAN_MAX_TOKEN :: 1024 * 1024

// cut 配置。Common_Config 必须是第一个字段（args.odin 的 ctx 约定）。
Cut_Config :: struct {
	using common: Common_Config,
	fields:           string, // 原始 -f 规格（如 "1,3-5,7-"）
	delimiter:        string, // -d（默认 tab）
	output_delimiter: string, // --output-delimiter（默认 = delimiter）
	skip_no_delimiter: bool,  // -s
	parsed_ranges:    [dynamic]Field_Range,
}

// cut 默认配置（gx cut.NewConfig）。
cut_new_config :: proc() -> Cut_Config {
	return Cut_Config{
		delimiter = "\t",
		common = {dry_run = true},
	}
}

// cut 选项表（gx cut.getOptions，4 项，顺序一致）。
cut_options :: proc() -> [4]Option {
	return {
		{short = "-f", long = "--fields", has_value = true, value_name = "LIST",
			help = "Field list (e.g. 1,3-5,7-,2-4)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Cut_Config)ctx
				c.fields = v
				return true
			}},
		{short = "-d", long = "--delimiter", has_value = true, value_name = "DELIM",
			help = "Field delimiter (default tab, supports \\t \\n \\\\)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Cut_Config)ctx
				c.delimiter = cut_unescape_delim(v)
				return true
			}},
		{short = "-s", long = "--only-delimited", help = "Skip lines without the delimiter",
			handler = proc(_: string, ctx: rawptr) -> bool {
				c := cast(^Cut_Config)ctx
				c.skip_no_delimiter = true
				return true
			}},
		{long = "--output-delimiter", has_value = true, value_name = "DELIM", help = "Output delimiter (default = -d)",
			handler = proc(v: string, ctx: rawptr) -> bool {
				c := cast(^Cut_Config)ctx
				c.output_delimiter = cut_unescape_delim(v)
				return true
			}},
	}
}

// cut 参数解析（gx cut.ParseArgs：裸 ParseSimple）。
cut_parse :: proc(argv: []string, c: ^Cut_Config) -> bool {
	opts := cut_options()
	return parse_simple(argv, &c.common, opts[:], cut_print_usage)
}

// cut_unescape_delim — 复刻 gx unescapeDelim：\t/\n/\\ 转义；空串回落 tab。
cut_unescape_delim :: proc(s: string) -> string {
	switch s {
	case `\t`:
		return "\t"
	case `\n`:
		return "\n"
	case `\\`:
		return `\`
	case "":
		return "\t"
	}
	return s
}

// cut_parse_fields — 复刻 gx parseFields：解析 "1,3-5,7-,-3" 为按 lo 稳定
// 排序的区间表。错误信息打印到 stderr（gx 的 "cut: %v" 形态），ok=false。
cut_parse_fields :: proc(spec: string) -> (ranges: [dynamic]Field_Range, ok: bool) {
	s := strings.trim_space(spec)
	if s == "" {
		fmt.fprintln(os.stderr, "cut: empty field list")
		return
	}
	parts := strings.split(s, ",")
	defer delete(parts) // split 只分配数组（元素是 s 的视图）
	for &part in parts {
		part = strings.trim_space(part)
		if part == "" {
			fmt.fprintf(os.stderr, "cut: empty field in list: %q\n", s)
			delete_dynamic_array(ranges)
			return
		}

		if i := strings.index_byte(part, '-'); i >= 0 {
			lo_str := part[:i]
			hi_str := part[i + 1:]
			// "-" 单独出现非法（POSIX 要求至少一个边界）
			if lo_str == "" && hi_str == "" {
				fmt.fprintf(os.stderr, "cut: bad field range %q\n", part)
				delete_dynamic_array(ranges)
				return
			}

			lo := 1
			if lo_str != "" {
				n, good := strconv.parse_int(lo_str)
				if !good || n < 1 {
					fmt.fprintf(os.stderr, "cut: bad field number %q\n", lo_str)
					delete_dynamic_array(ranges)
					return
				}
				lo = n
			}
			hi := -1
			if hi_str != "" {
				n, good := strconv.parse_int(hi_str)
				if !good || n < 1 {
					fmt.fprintf(os.stderr, "cut: bad field number %q\n", hi_str)
					delete_dynamic_array(ranges)
					return
				}
				if n < lo {
					fmt.fprintf(os.stderr, "cut: bad range %q: high < low\n", part)
					delete_dynamic_array(ranges)
					return
				}
				hi = n
			}
			// 存 0-based 闭区间；开放形态 hi 保持 -1 哨兵
			store_hi := hi - 1
			if hi == -1 {
				store_hi = -1
			}
			append(&ranges, Field_Range{lo = lo - 1, hi = store_hi})
			continue
		}

		n, good := strconv.parse_int(part)
		if !good || n < 1 {
			fmt.fprintf(os.stderr, "cut: bad field number %q\n", part)
			delete_dynamic_array(ranges)
			return
		}
		append(&ranges, Field_Range{lo = n - 1, hi = n - 1})
	}

	// 按 lo 稳定排序（手写插入排序：区间表极小，且保序与 Go sort.Slice
	// 在小输入下的插入排序行为一致——重复 lo 时相对顺序不变）
	for i := 1; i < len(ranges); i += 1 {
		j := i
		for j > 0 && ranges[j - 1].lo > ranges[j].lo {
			ranges[j - 1], ranges[j] = ranges[j], ranges[j - 1]
			j -= 1
		}
	}
	ok = true
	return
}

// scan_lines — 复刻 Go bufio.Scanner + ScanLines 的行切分：按 \n 切分、
// 剥掉行尾 \r、末尾换行不产生额外空行、空输入零行。
// max_token 复刻 gx 的 scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)：
// 原始行（含 \r、不含 \n）长度达到该值即触发 bufio.ErrTooLong——此时
// ok=false，该行及其后内容全部丢弃（gx 的 for scanner.Scan() 直接中断，
// 已产出的行照常输出，随后命令打印 "bufio.Scanner: token too long" 退出 2；
// find 不检查 scanner.Err()，静默丢弃）。
// 返回的字符串均为 data 的零拷贝视图（不拷贝字节，调用方持有数据）。
scan_lines :: proc(data: []u8, max_token := SCAN_MAX_TOKEN) -> (lines: [dynamic]string, ok: bool) {
	start := 0
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			if i - start >= max_token {
				return lines, false // bufio.ErrTooLong
			}
			end := i
			if end > start && data[end - 1] == '\r' {
				end -= 1
			}
			append(&lines, string(data[start:end]))
			start = i + 1
		}
	}
	if start < len(data) {
		if len(data) - start >= max_token {
			return lines, false // bufio.ErrTooLong
		}
		end := len(data)
		if end > start && data[end - 1] == '\r' {
			end -= 1
		}
		append(&lines, string(data[start:end]))
	}
	return lines, true
}

// cut_cut_line — 单行字段提取（复刻 gx cutLine）。无分隔符 → 原样返回。
// parts 数组由 strings.split 分配（元素是 line 的视图），需 delete。
cut_cut_line :: proc(c: ^Cut_Config, line: string, out_delim: string) -> string {
	if !strings.contains(line, c.delimiter) {
		return line
	}
	parts := strings.split(line, c.delimiter)
	defer delete(parts)
	picked: [dynamic]string
	defer delete_dynamic_array(picked)
	for r in c.parsed_ranges {
		hi := r.hi
		if hi == -1 || hi >= len(parts) {
			hi = len(parts) - 1 // 开放或越界 → 夹到行尾
		}
		for idx := r.lo; idx <= hi; idx += 1 {
			if idx < len(parts) {
				append(&picked, parts[idx])
			}
		}
	}
	return strings.join(picked[:], out_delim)
}

// cut 用法（gx cut.printUsage）。
cut_print_usage :: proc() {
	opts := cut_options()
	text := format_options(opts[:])
	defer delete(text)
	fmt.printfln(`cut - Extract fields from delimited text (only -f mode)

Usage: cut -f LIST [OPTIONS] [FILE]

Options:
%s
Field LIST syntax:
  N       field N (1-based)
  N-M     fields N through M (inclusive)
  N-      fields N through end of line
  -M      fields 1 through M

Examples:
  cut -f 2 -d , file.csv
  cut -f 1,3 -d '\\t' file.tsv
  cut -f 2- -d ',' file.csv
  cat file | odd cut -f 1 -d ':'`, text)
}

// run_cut — cut 入口（完整实现）。退出码：0 成功 / 2 参数或 IO 错误。
run_cut :: proc(argv: []string) -> int {
	c := cut_new_config()
	defer delete_dynamic_array(c.paths)
	defer delete_dynamic_array(c.parsed_ranges)
	if !cut_parse(argv, &c) {
		return 2
	}
	if c.fields == "" {
		fmt.fprintln(os.stderr, "cut: -f is required")
		return 2
	}

	ranges, ok := cut_parse_fields(c.fields)
	if !ok {
		return 2 // 错误信息已在 cut_parse_fields 内打印
	}
	c.parsed_ranges = ranges

	// cut 无 Pattern 概念；ParseCommon 把第一个位置参塞进了 pattern。
	// 把它取回作为输入路径；没有则 stdin（gx 原样）。
	input := c.pattern
	paths := make([]string, 1)
	defer delete(paths)
	if input != "" {
		paths[0] = input
	} else {
		paths[0] = "-" // stdin 标记
	}

	out_delim := c.output_delimiter
	if out_delim == "" {
		out_delim = c.delimiter
	}

	data, _, read_ok := engine.read_all(paths)
	defer delete(data)
	if !read_ok {
		print_input_error("cut", paths[0])
		return 2
	}

	lines, scan_ok := scan_lines(data)
	defer delete_dynamic_array(lines)
	out: [dynamic]u8
	defer delete_dynamic_array(out)
	for line in lines {
		if !strings.contains(line, c.delimiter) {
			if c.skip_no_delimiter {
				continue // -s：整行跳过
			}
			append(&out, ..transmute([]u8)line)
			append(&out, '\n')
			continue
		}
		picked := cut_cut_line(&c, line, out_delim)
		append(&out, ..transmute([]u8)picked)
		delete(picked)
		append(&out, '\n')
	}
	os.write(os.stdout, out[:])
	if !scan_ok {
		// gx：scanner.Err() != nil → "cut: bufio.Scanner: token too long"，退出 2
		fmt.fprintln(os.stderr, "cut: bufio.Scanner: token too long")
		return 2
	}
	return 0
}
