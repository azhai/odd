package app

// ============================================================================
// args_test.odin — 参数解析层测试（对齐 gx args 包语义）
//
// 覆盖 parse_simple / parse_common / format_options / parse_int_prefix /
// parse_duration，以及 ctx 约定（using common 首字段地址等价）。
// ============================================================================

import "core:testing"
import "core:time"

// 测试用配置：using common 首字段 + 两个自有选项字段。
Test_Cfg :: struct {
	using common: Common_Config,
	flag_a:       bool,
	value_b:      string,
}

// 测试选项表：flag（-a/--all-test）、带值（-b/--bee）、失败型（--bad）。
// 必须是**可寻址**的包级变量——Odin 不允许切片 proc 的返回值
// （test_options()[:] 会报 "value is not addressable"）。
TEST_OPTIONS: [3]Option = {
	{short = "-a", long = "--all-test", help = "flag a",
		handler = proc(_: string, ctx: rawptr) -> bool {
			c := cast(^Test_Cfg)ctx
			c.flag_a = true
			return true
		}},
	{short = "-b", long = "--bee", has_value = true, value_name = "V", help = "value b",
		handler = proc(v: string, ctx: rawptr) -> bool {
			c := cast(^Test_Cfg)ctx
			c.value_b = v
			return true
		}},
	{long = "--bad", help = "always fails",
		handler = proc(_: string, ctx: rawptr) -> bool {
			return false
		}},
}

// 选项表切片（每次解析调用前现取，避免悬垂）。
test_options :: proc() -> []Option {
	return TEST_OPTIONS[:]
}

// 静默用法（测试中不打印）。
test_usage :: proc() {}

@(test)
test_parse_simple_one_arg :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	ok := parse_simple({"pattern"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "1 参应解析成功")
	testing.expectf(t, c.pattern == "pattern", "pattern  got %q", c.pattern)
	testing.expectf(t, len(c.paths) == 1 && c.paths[0] == ".", "paths 应默认 [.]，got %v", c.paths)
	testing.expect(t, !c.replace_set, "replace 不应设置")
}

@(test)
test_parse_simple_two_args :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// 2 参智能模式：第二参是**路径**而非替换串（find 语义）
	ok := parse_simple({"pat", "dir"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "2 参应解析成功")
	testing.expectf(t, c.pattern == "pat", "pattern got %q", c.pattern)
	testing.expectf(t, len(c.paths) == 1 && c.paths[0] == "dir", "paths 应为 [dir]，got %v", c.paths)
	testing.expect(t, !c.replace_set, "replace 不应设置")
}

@(test)
test_parse_simple_zero_args :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	ok := parse_simple({}, &c.common, test_options()[:], test_usage)
	testing.expect(t, !ok, "0 参应失败")
}

@(test)
test_parse_simple_help_flag :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	testing.expect(t, !parse_simple({"-h"}, &c.common, test_options()[:], test_usage), "-h 应失败")
	c2: Test_Cfg
	defer delete_dynamic_array(c2.paths)
	testing.expect(t, !parse_simple({"pat", "--help"}, &c.common, test_options()[:], test_usage), "中间夹 --help 也应失败")
}

@(test)
test_parse_simple_with_option :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// 出现已注册选项 → 走 ParseCommon 完整链
	ok := parse_simple({"-a", "pat", "repl", "dir"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "带选项应解析成功")
	testing.expect(t, c.flag_a, "-a 应置位")
	testing.expectf(t, c.pattern == "pat", "pattern got %q", c.pattern)
	testing.expectf(t, c.replace == "repl" && c.replace_set, "replace got %q set=%v", c.replace, c.replace_set)
	testing.expectf(t, len(c.paths) == 1 && c.paths[0] == "dir", "paths got %v", c.paths)
}

@(test)
test_parse_common_option_with_value :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	ok := parse_common({"-b", "hello", "pat"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "应成功")
	testing.expectf(t, c.value_b == "hello", "value_b got %q", c.value_b)
	testing.expectf(t, c.pattern == "pat", "pattern got %q", c.pattern)
}

@(test)
test_parse_common_long_option :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	ok := parse_common({"--bee", "x", "--all-test"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "长名应成功")
	testing.expectf(t, c.value_b == "x", "value_b got %q", c.value_b)
	testing.expect(t, c.flag_a, "长名 flag 应置位")
}

@(test)
test_parse_common_missing_value :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// 带值选项在末尾 → 缺值失败
	testing.expect(t, !parse_common({"pat", "-b"}, &c.common, test_options()[:], test_usage), "缺值应失败")
}

@(test)
test_parse_common_handler_false :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// handler 返回 false → 整体失败
	testing.expect(t, !parse_common({"--bad"}, &c.common, test_options()[:], test_usage), "handler 失败应传导")
}

@(test)
test_parse_common_unknown_option_is_positional :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// 未注册的 -z 按位置参处理（gx 原样）
	ok := parse_common({"-z", "pat"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "应成功")
	testing.expectf(t, c.pattern == "-z", "第一个位置参是 -z，got %q", c.pattern)
	testing.expectf(t, c.replace == "pat" && c.replace_set, "第二个位置参进 replace，got %q", c.replace)
}

@(test)
test_parse_common_positional_chain :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	ok := parse_common({"p1", "p2", "p3", "p4"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "应成功")
	testing.expectf(t, c.pattern == "p1", "p1 got %q", c.pattern)
	testing.expectf(t, c.replace == "p2", "p2 got %q", c.replace)
	testing.expectf(t, len(c.paths) == 2 && c.paths[0] == "p3" && c.paths[1] == "p4", "p3/p4 got %v", c.paths)
}

@(test)
test_parse_common_empty_pattern_stays_open :: proc(t: ^testing.T) {
	c: Test_Cfg
	defer delete_dynamic_array(c.paths)
	// gx 怪癖：pattern == "" 判定使空串位置参被后续位置参覆盖
	ok := parse_common({"", "pat"}, &c.common, test_options()[:], test_usage)
	testing.expect(t, ok, "应成功")
	testing.expectf(t, c.pattern == "pat", "空串后 pattern 应被 pat 覆盖，got %q", c.pattern)
}

@(test)
test_format_options_shapes :: proc(t: ^testing.T) {
	opts := [4]Option{
		{short = "-i", long = "--ignore-case", help = "Case insensitive"},
		{short = "-g", long = "--glob", has_value = true, value_name = "PATTERN", help = "File glob"},
		{short = "-x", help = "Only short"},
		{long = "--only-long", help = "Only long"},
	}
	text := format_options(opts[:])
	defer delete(text)
	want := "  -i, --ignore-case    Case insensitive\n" +
		"  -g, --glob <PATTERN>    File glob\n" +
		"  -x    Only short\n" +
		"  --only-long    Only long\n"
	testing.expectf(t, text == want, "格式不符:\ngot  %q\nwant %q", text, want)
}

@(test)
test_parse_int_prefix :: proc(t: ^testing.T) {
	n := 7
	testing.expect(t, parse_int_prefix("12abc", &n), "12abc 应解析")
	testing.expectf(t, n == 12, "got %d", n)
	n = 7
	testing.expect(t, parse_int_prefix("-5", &n), "-5 应解析")
	testing.expectf(t, n == -5, "got %d", n)
	n = 7
	testing.expect(t, parse_int_prefix("+3", &n), "+3 应解析")
	testing.expectf(t, n == 3, "got %d", n)
	n = 7
	testing.expect(t, parse_int_prefix("0", &n), "0 应解析")
	testing.expectf(t, n == 0, "got %d", n)
	n = 7
	testing.expect(t, !parse_int_prefix("abc", &n), "abc 应失败")
	testing.expectf(t, n == 7, "失败时应保持原值，got %d", n)
	n = 7
	testing.expect(t, !parse_int_prefix("", &n), "空串应失败")
	testing.expectf(t, n == 7, "失败时应保持原值，got %d", n)
}

@(test)
test_parse_duration :: proc(t: ^testing.T) {
	d, ok := parse_duration("500ms")
	testing.expect(t, ok, "500ms 应解析")
	testing.expectf(t, d == 500 * time.Millisecond, "got %v", d)
	d, ok = parse_duration("2s")
	testing.expect(t, ok && d == 2 * time.Second, "2s")
	d, ok = parse_duration("1.5h")
	testing.expectf(t, ok && d == 90 * time.Minute, "1.5h  got %v", d)
	d, ok = parse_duration("1h30m")
	testing.expectf(t, ok && d == 90 * time.Minute, "1h30m got %v", d)
	d, ok = parse_duration("100ns")
	testing.expect(t, ok && d == 100 * time.Nanosecond, "100ns")
	d, ok = parse_duration("2us")
	testing.expect(t, ok && d == 2 * time.Microsecond, "2us")
	_, ok = parse_duration("bad")
	testing.expect(t, !ok, "bad 应失败")
	_, ok = parse_duration("5")
	testing.expect(t, !ok, "无单位应失败")
	_, ok = parse_duration("")
	testing.expect(t, !ok, "空串应失败")
	_, ok = parse_duration("5x")
	testing.expect(t, !ok, "坏单位应失败")
}

@(test)
test_ctx_convention_first_field :: proc(t: ^testing.T) {
	// using common 首字段 → rawptr(&c) == rawptr(&c.common)，
	// 这是 handler 里 cast(^Xxx_Config)ctx 的前提
	c: Test_Cfg
	testing.expect(t, rawptr(&c) == rawptr(&c.common), "首字段地址应等价")
}

// 注：各命令 print_usage 的覆盖不在这里。
// 它们直接写 os.stdout，单测里只能"调一次看崩不崩"，还会把几百行 usage
// 灌进测试日志；而 tests/run.sh 的 7 条 `<cmd> --help` 用例是逐字节比对
// stdout + 退出码的，覆盖强得多。所以这里刻意不测。
