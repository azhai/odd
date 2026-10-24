package lib

// ============================================================================
// lib_test.odin — lib 包单测（sizeexpr / timeexpr / format / gitignore / base）
//
// 为什么补这一批：lib 是依赖图的根，之前一个单测都没有，全靠差分矩阵间接
// 覆盖。差分只能看见"最终输出一致"，看不见内部函数被喂了什么；一旦后面要
// 动算法（如把 format_* 改成零分配写入 builder），没有函数级断言就无从验证
// 等价性。
//
// 约定：
//   * 返回堆字符串的 proc（format_size / format_fixed_width / format_time）
//     其结果必须由测试 delete，否则内存追踪会报泄漏。
//   * 时间断言一律走「绝对 civil ↔ time.Time 往返」而不是硬编码 UTC 期望值，
//     这样测试与机器时区无关。
//   * 切片字面量不能直接写在 `for ... in` 头部（解析器歧义），先赋给局部变量，
//     见 AGENTS.md 踩坑清单 #18。
// ============================================================================

import "core:strings"
import "core:testing"
import "core:time"

// 字符串相等断言（带上下文，便于定位是哪一条比较失败）。
expect_str :: proc(t: ^testing.T, got, want: string, ctx_msg: string) {
	testing.expectf(t, got == want, "%s: got %q want %q", ctx_msg, got, want)
}

// ---------------------------------------------------------------------------
// sizeexpr
// ---------------------------------------------------------------------------

@(test)
test_parse_operator :: proc(t: ^testing.T) {
	op1, r1 := parse_operator("<=1K")
	testing.expect(t, op1 == .LE && r1 == "1K", "<= 应识别为 LE")
	op2, r2 := parse_operator(">=10")
	testing.expect(t, op2 == .GE && r2 == "10", ">= 应识别为 GE")
	op3, r3 := parse_operator("<5")
	testing.expect(t, op3 == .LT && r3 == "5", "< 应识别为 LT")
	op4, r4 := parse_operator(">5")
	testing.expect(t, op4 == .GT && r4 == "5", "> 应识别为 GT")
	op5, r5 := parse_operator("1024")
	testing.expect(t, op5 == .EQ && r5 == "1024", "无前缀应为 EQ")

	// 只有 "=" 不构成合法运算符（gx 不支持裸 = ）
	op6, r6 := parse_operator("=5")
	testing.expect(t, op6 == .EQ && r6 == "=5", "裸 = 不当作运算符前缀")
}

@(test)
test_split_number_unit :: proc(t: ^testing.T) {
	n1, u1 := split_number_unit("1024")
	expect_str(t, n1, "1024", "纯数字 num")
	expect_str(t, u1, "", "纯数字 unit")
	n2, u2 := split_number_unit("1.5K")
	expect_str(t, n2, "1.5", "小数 num")
	expect_str(t, u2, "K", "小数 unit")
	n3, u3 := split_number_unit(".5M")
	expect_str(t, n3, ".5", "前导小数点 num")
	expect_str(t, u3, "M", "前导小数点 unit")
	n4, u4 := split_number_unit("K")
	expect_str(t, n4, "", "无数字 num")
	expect_str(t, u4, "K", "无数字 unit")
	n5, u5 := split_number_unit("")
	expect_str(t, n5, "", "空串 num")
	expect_str(t, u5, "", "空串 unit")
}

@(test)
test_parse_size_expr_units :: proc(t: ^testing.T) {
	f1, ok1 := parse_size_expr("1024")
	testing.expect(t, ok1 && f1.op == .EQ && f1.value == 1024, "无单位 = 字节")
	f2, ok2 := parse_size_expr(">1K")
	testing.expect(t, ok2 && f2.op == .GT && f2.value == 1024, "K = 1024")
	f3, ok3 := parse_size_expr("<=1M")
	testing.expect(t, ok3 && f3.op == .LE && f3.value == 1024 * 1024, "M = 1024^2")
	f4, ok4 := parse_size_expr("1G")
	testing.expect(t, ok4 && f4.value == 1024 * 1024 * 1024, "G = 1024^3")
	f5, ok5 := parse_size_expr("1.5K")
	testing.expect(t, ok5 && f5.value == 1536, "1.5K = 1536")
	// 单位大小写不敏感
	f6, ok6 := parse_size_expr("<1g")
	testing.expect(t, ok6 && f6.op == .LT && f6.value == 1024 * 1024 * 1024, "小写 g 也应识别")
}

@(test)
test_parse_size_expr_rejects :: proc(t: ^testing.T) {
	bad := []string{"", "abc", "K", "<=1X", "-5", ">-1K", "<="}
	for e in bad {
		_, ok := parse_size_expr(e)
		testing.expectf(t, !ok, "%q 应解析失败", e)
	}
}

@(test)
test_size_match_ops :: proc(t: ^testing.T) {
	testing.expect(t, size_match(Size_Filter{op = .LT, value = 100}, 99), "LT 应命中更小值")
	testing.expect(t, !size_match(Size_Filter{op = .LT, value = 100}, 100), "LT 边界不命中")
	testing.expect(t, size_match(Size_Filter{op = .LE, value = 100}, 100), "LE 边界命中")
	testing.expect(t, size_match(Size_Filter{op = .GT, value = 100}, 101), "GT 应命中更大值")
	testing.expect(t, !size_match(Size_Filter{op = .GT, value = 100}, 100), "GT 边界不命中")
	testing.expect(t, size_match(Size_Filter{op = .GE, value = 100}, 100), "GE 边界命中")
	testing.expect(t, size_match(Size_Filter{op = .EQ, value = 100}, 100), "EQ 命中")
	testing.expect(t, !size_match(Size_Filter{op = .EQ, value = 100}, 99), "EQ 不命中")
	// 枚举越界（防御性 default 分支）
	testing.expect(t, !size_match(Size_Filter{op = cast(Operator)99, value = 1}, 1), "未知运算符不命中")
}

// ---------------------------------------------------------------------------
// timeexpr
// ---------------------------------------------------------------------------

@(test)
test_time_diff_direction :: proc(t: ^testing.T) {
	a := time.from_nanoseconds(10 * i64(time.Second))
	b := time.from_nanoseconds(3 * i64(time.Second))
	// time_diff(a, b) 必须是 a - b = +7s
	// （core:time 的 time.diff(start, end) 返回 end - start，名字与直觉相反）
	testing.expectf(t, time_diff(a, b) == 7 * time.Second, "time_diff(a,b) 应为 a-b=7s, got %v", time_diff(a, b))
	testing.expect(t, time_diff(b, a) == -7 * time.Second, "反向应为 -7s")
	testing.expect(t, time_diff(a, a) == 0, "相同时间差为 0")
}

@(test)
test_time_before_after :: proc(t: ^testing.T) {
	earlier := time.from_nanoseconds(1 * i64(time.Second))
	later := time.from_nanoseconds(2 * i64(time.Second))
	testing.expect(t, time_before(earlier, later), "earlier 应在 later 之前")
	testing.expect(t, !time_before(later, earlier), "later 不在 earlier 之前")
	testing.expect(t, !time_before(earlier, earlier), "相同时间不算之前")
	testing.expect(t, time_after(later, earlier), "later 应在 earlier 之后")
	testing.expect(t, !time_after(earlier, earlier), "相同时间不算之后")
}

@(test)
test_is_relative_time :: proc(t: ^testing.T) {
	rel := []string{"30s", "5m", "1h", "7d", "2w"}
	for s in rel {
		testing.expectf(t, is_relative_time(s), "%q 应判定为相对时间", s)
	}
	abs := []string{"", "2025-01-01", "2025-01-01T10:00:00", "abc"}
	for s in abs {
		testing.expectf(t, !is_relative_time(s), "%q 不应判定为相对时间", s)
	}
}

@(test)
test_parse_relative_duration :: proc(t: ^testing.T) {
	Duration_Case :: struct {
		expr: string,
		want: time.Duration,
	}
	cases := []Duration_Case{
		{"30s", 30 * time.Second},
		{"1m", 60 * time.Second},
		{"2h", 2 * time.Hour},
		{"7d", 7 * 24 * time.Hour},
		{"2w", 14 * 24 * time.Hour},
		{"1.5h", 90 * time.Minute},
		{"0s", 0},
	}
	for c in cases {
		d, ok := parse_relative_duration(c.expr)
		testing.expectf(t, ok, "%q 应解析成功", c.expr)
		testing.expectf(t, d == c.want, "%q: got %v want %v", c.expr, d, c.want)
	}

	bad := []string{"", "s", "abc", "-1h", "h"}
	for s in bad {
		_, ok := parse_relative_duration(s)
		testing.expectf(t, !ok, "%q 应解析失败", s)
	}
}

@(test)
test_invert_operator :: proc(t: ^testing.T) {
	testing.expect(t, invert_operator(.LT) == .GT, "LT → GT")
	testing.expect(t, invert_operator(.LE) == .GE, "LE → GE")
	testing.expect(t, invert_operator(.GT) == .LT, "GT → LT")
	testing.expect(t, invert_operator(.GE) == .LE, "GE → LE")
	testing.expect(t, invert_operator(.EQ) == .EQ, "EQ 取反仍是 EQ")
	// 两次取反回到原值
	ops := []Operator{.LT, .LE, .GT, .GE, .EQ}
	for op in ops {
		testing.expectf(t, invert_operator(invert_operator(op)) == op, "%v 两次取反应复原", op)
	}
}

@(test)
test_parse_absolute_time_ok :: proc(t: ^testing.T) {
	t1, ok1 := parse_absolute_time("2025-01-01")
	testing.expect(t, ok1, "YYYY-MM-DD 应解析成功")
	y, mo, d, h, mi, s, okCivil := local_civil(t1)
	testing.expect(t, okCivil, "local_civil 应成功")
	testing.expectf(
		t,
		y == 2025 && mo == 1 && d == 1 && h == 0 && mi == 0 && s == 0,
		"日期应还原为 2025-01-01 00:00:00, got %d-%d-%d %d:%d:%d",
		y, mo, d, h, mi, s,
	)

	t2, ok2 := parse_absolute_time("2025-06-15T08:30:45")
	testing.expect(t, ok2, "带时间的绝对表达式应解析成功")
	y2, mo2, d2, h2, mi2, s2, _ := local_civil(t2)
	testing.expectf(
		t,
		y2 == 2025 && mo2 == 6 && d2 == 15 && h2 == 8 && mi2 == 30 && s2 == 45,
		"应还原为 2025-06-15 08:30:45, got %d-%d-%d %d:%d:%d",
		y2, mo2, d2, h2, mi2, s2,
	)
}

@(test)
test_parse_absolute_time_rejects :: proc(t: ^testing.T) {
	bad := []string{
		"", "abc", "20250101", "2025-13-01", "2025-00-10", "2025-01-32",
		"2025-01-01T25:00:00", "2025-01-01T12:60:00", "2025-01-01T12:00:60",
		"2025-01-01T12:00", "2025-01", "2025-1-1",
	}
	for s in bad {
		_, ok := parse_absolute_time(s)
		testing.expectf(t, !ok, "%q 应解析失败", s)
	}
}

@(test)
test_civil_local_roundtrip :: proc(t: ^testing.T) {
	// civil_to_time 的翻译再经 local_civil 分解应原样回来（与机器时区无关）
	cases := [][6]int{{2026, 1, 1, 0, 0, 0}, {2026, 10, 25, 6, 59, 59}, {1999, 12, 31, 23, 59, 59}}
	for c in cases {
		tm := civil_to_time(i64(c[0]), i64(c[1]), i64(c[2]), i64(c[3]), i64(c[4]), i64(c[5]))
		y, mo, d, h, mi, s, ok := local_civil(tm)
		testing.expectf(t, ok, "%v local_civil 应成功", c)
		testing.expectf(
			t,
			y == c[0] && mo == c[1] && d == c[2] && h == c[3] && mi == c[4] && s == c[5],
			"往返失败: got %d-%d-%dT%d:%d:%d want %d-%d-%dT%d:%d:%d",
			y, mo, d, h, mi, s, c[0], c[1], c[2], c[3], c[4], c[5],
		)
	}
}

@(test)
test_format_time_civil :: proc(t: ^testing.T) {
	buf: [19]u8
	expect_str(t, format_time_civil(civil_to_time(2026, 10, 25, 6, 7, 8), buf[:]), "2026-10-25T06:07:08", "零填充的 civil 格式")
	buf2: [19]u8
	expect_str(t, format_time_civil(civil_to_time(2025, 12, 31, 23, 59, 59), buf2[:]), "2025-12-31T23:59:59", "年末边界")
	buf3: [19]u8
	s3 := format_time_civil(civil_to_time(2026, 1, 2, 3, 4, 5), buf3[:])
	testing.expect(t, len(s3) == 19, "长度应恒为 19")
	testing.expect(t, s3[4] == '-' && s3[7] == '-' && s3[10] == 'T' && s3[13] == ':' && s3[16] == ':', "分隔符位置应固定")
}

@(test)
test_time_is_zero :: proc(t: ^testing.T) {
	testing.expect(t, time_is_zero({}), "零值时间应判定为 zero")
	testing.expect(t, !time_is_zero(civil_to_time(2026, 1, 1, 0, 0, 0)), "非零时间不应判定为 zero")
}

@(test)
test_time_match_absolute :: proc(t: ^testing.T) {
	now := civil_to_time(2026, 6, 1, 12, 0, 0)
	target := civil_to_time(2026, 5, 1, 0, 0, 0)

	f, ok := parse_time_expr(">=2026-01-01", now)
	testing.expect(t, ok, "绝对表达式应解析成功")
	testing.expect(t, time_match(f, target), "2026-05-01 应满足 >=2026-01-01")
	testing.expect(t, !time_match(f, civil_to_time(2025, 12, 31, 23, 59, 59)), "2025 不应满足")

	f2, _ := parse_time_expr("<2026-01-01", now)
	testing.expect(t, time_match(f2, civil_to_time(2025, 6, 1, 0, 0, 0)), "2025 应满足 <2026-01-01")
	testing.expect(t, !time_match(f2, target), "2026-05-01 不应满足 <2026-01-01")
}

@(test)
test_time_match_relative :: proc(t: ^testing.T) {
	now := civil_to_time(2026, 6, 1, 12, 0, 0)
	// "<=1h" 语义 = 落在最近一小时（运算符取反后与 now-1h 比较）
	f, ok := parse_time_expr("<=1h", now)
	testing.expect(t, ok, "相对表达式应解析成功")
	testing.expect(t, f.op == .GE, "<=1h 内部应转为 GE")

	within := time_time_add(now, -30 * time.Minute)
	outside := time_time_add(now, -2 * time.Hour)
	testing.expect(t, time_match(f, now), "now 自己应满足 <=1h")
	testing.expect(t, time_match(f, within), "30 分钟前应满足 <=1h")
	testing.expect(t, !time_match(f, outside), "2 小时前不应满足 <=1h")

	// ">1d"：早于一天前
	f2, _ := parse_time_expr(">1d", now)
	old := time_time_add(now, -2 * 24 * time.Hour)
	testing.expect(t, time_match(f2, old), "两天前应满足 >1d")
	testing.expect(t, !time_match(f2, within), "半小时前不应满足 >1d")
}

@(test)
test_parse_time_expr_rejects :: proc(t: ^testing.T) {
	now := civil_to_time(2026, 6, 1, 12, 0, 0)
	bad := []string{"", "abc", "1x", "-1h", "<=abc", "2025-13-01"}
	for e in bad {
		_, ok := parse_time_expr(e, now)
		testing.expectf(t, !ok, "%q 应解析失败", e)
	}
}

// ---------------------------------------------------------------------------
// format
// ---------------------------------------------------------------------------

@(test)
test_format_size :: proc(t: ^testing.T) {
	Size_Case :: struct {
		n:    i64,
		want: string,
	}
	cases := []Size_Case{
		{0, "0"},
		{1, "1"},
		{1023, "1023"},
		{1024, "1.0K"},
		{1536, "1.5K"},
		{1048576, "1.0M"},
		{1073741824, "1.0G"},
	}
	for c in cases {
		got := format_size(c.n)
		expect_str(t, got, c.want, "format_size")
		delete(got)
	}
}

@(test)
test_format_fixed_width :: proc(t: ^testing.T) {
	// 右对齐左补空格
	got1 := format_fixed_width("ab", 5, true)
	expect_str(t, got1, "   ab", "右对齐补左空格")
	delete(got1)

	// 左对齐右补空格
	got2 := format_fixed_width("ab", 5, false)
	expect_str(t, got2, "ab   ", "左对齐补右空格")
	delete(got2)

	// 等长不补
	got3 := format_fixed_width("abc", 3, true)
	expect_str(t, got3, "abc", "等长原样返回")
	delete(got3)

	// 超宽且 width > 3：截断到 width-3 并加 "..."
	got4 := format_fixed_width("abcdefghij", 6, true)
	expect_str(t, got4, "abc...", "超宽应截断并补省略号")
	delete(got4)

	// 超宽且 width <= 3：硬截
	got5 := format_fixed_width("abcdef", 3, true)
	expect_str(t, got5, "abc", "width<=3 应硬截")
	delete(got5)

	// 空串也要补齐宽度
	got6 := format_fixed_width("", 3, true)
	expect_str(t, got6, "   ", "空串补满宽度")
	delete(got6)
}

@(test)
test_format_time_zero :: proc(t: ^testing.T) {
	got := format_time({})
	expect_str(t, got, "                   ", "零值时间应为 19 个空格")
	testing.expect(t, len(got) == 19, "零值占位长度应为 19")
	delete(got)

	got2 := format_time(civil_to_time(2026, 10, 25, 6, 7, 8))
	expect_str(t, got2, "2026-10-25T06:07:08", "非零时间应格式化为 civil 字符串")
	delete(got2)
}

@(test)
test_default_column_widths :: proc(t: ^testing.T) {
	w := default_column_widths()
	testing.expect(t, w.size == 10, "size 列宽应为 10")
	testing.expect(t, w.time == 19, "time 列宽应为 19（civil 串长度）")
	testing.expect(t, w.path == 40, "path 列宽应为 40")
}

// ---------------------------------------------------------------------------
// gitignore
// ---------------------------------------------------------------------------

@(test)
test_parse_gitignore_pattern :: proc(t: ^testing.T) {
	// 普通规则
	p1, ok1 := parse_gitignore_pattern("*.log")
	testing.expect(t, ok1, "普通规则应解析成功")
	expect_str(t, p1.pattern, "*.log", "普通规则 pattern")
	testing.expect(t, !p1.negated && !p1.dir_only && !p1.rooted, "普通规则三个标志都应为 false")

	// 注释 / 空行
	skip := []string{"", "# comment", "   ", "#"}
	for s in skip {
		_, ok := parse_gitignore_pattern(s)
		testing.expectf(t, !ok, "%q 应被跳过", s)
	}

	// 行尾空格被剥离（trailing-space 不参与匹配）
	p2, ok2 := parse_gitignore_pattern("foo   ")
	testing.expect(t, ok2, "行尾空格应被剥离")
	expect_str(t, p2.pattern, "foo", "剥离后的 pattern")

	// 仅目录
	p3, _ := parse_gitignore_pattern("build/")
	testing.expect(t, p3.dir_only, "build/ 应标记 dir_only")
	expect_str(t, p3.pattern, "build", "dir_only 的 pattern 不含尾部 /")

	// 根锚定
	p4, _ := parse_gitignore_pattern("/tmp")
	testing.expect(t, p4.rooted, "/tmp 应标记 rooted")
	expect_str(t, p4.pattern, "tmp", "rooted 的 pattern 不含前导 /")

	// 取反
	p5, _ := parse_gitignore_pattern("!keep.txt")
	testing.expect(t, p5.negated, "! 应标记 negated")
	expect_str(t, p5.pattern, "keep.txt", "negated 的 pattern")

	// 转义的行首 #（`\#` → 字面 #）
	p6, ok6 := parse_gitignore_pattern(`\#literal`)
	testing.expect(t, ok6, "转义 # 应解析成功")
	expect_str(t, p6.pattern, "#literal", "转义 # 的 pattern")

	// 只剩 "/" 的行：剥离后为空 → 跳过
	_, ok7 := parse_gitignore_pattern("/")
	testing.expect(t, !ok7, "只含 / 的行应被跳过")
}

@(test)
test_pattern_match :: proc(t: ^testing.T) {
	p1 := Gitignore_Pattern{pattern = "*.log"}
	testing.expect(t, pattern_match(p1, "app.log", false), "*.log 应命中文件")
	testing.expect(t, !pattern_match(p1, "app.txt", false), "*.log 不应命中 .txt")

	// dir_only 对文件不生效，对目录生效
	p2 := Gitignore_Pattern{pattern = "build", dir_only = true}
	testing.expect(t, !pattern_match(p2, "build", false), "dir_only 不应命中同名文件")
	testing.expect(t, pattern_match(p2, "build", true), "dir_only 应命中同名目录")

	// glob 语法错误（未闭合 [）按"不命中"处理，不传播错误
	p3 := Gitignore_Pattern{pattern = "a[b"}
	testing.expect(t, !pattern_match(p3, "a[b", false), "非法 glob 应不命中")

	// 字面名精确匹配
	p4 := Gitignore_Pattern{pattern = "Makefile"}
	testing.expect(t, pattern_match(p4, "Makefile", false), "精确名应命中")
	testing.expect(t, !pattern_match(p4, "Makefile.bak", false), "不应命中后缀不同的名字")
}

@(test)
test_gitignore_matcher_inheritance :: proc(t: ^testing.T) {
	alloc := context.allocator

	parent_content := "*.log\n"
	parent := new_gitignore_matcher(parent_content, nil, alloc)
	defer destroy_gitignore_matcher(parent, alloc)
	testing.expectf(t, len(parent.patterns) == 1, "父应有 1 条规则, got %d", len(parent.patterns))

	// 子继承父的结论
	child_content := "!debug.log\n"
	child := new_gitignore_matcher(child_content, parent, alloc)
	defer destroy_gitignore_matcher(child, alloc)

	testing.expect(t, match(child, "app.log", false), "父规则 *.log 应被子继承")
	testing.expect(t, !match(child, "debug.log", false), "子的 !debug.log 应覆盖父规则")
	testing.expect(t, !match(child, "app.txt", false), "未命中任何规则的文件不忽略")

	// 同层后者覆盖前者
	multi_content := "*.log\n!keep.log\n"
	multi := new_gitignore_matcher(multi_content, nil, alloc)
	defer destroy_gitignore_matcher(multi, alloc)
	testing.expect(t, match(multi, "a.log", false), "第一条 *.log 命中")
	testing.expect(t, !match(multi, "keep.log", false), "后写的 !keep.log 应覆盖")

	// nil matcher 恒不命中（与实现的 nil 短路一致）
	testing.expect(t, !match(nil, "anything", false), "nil matcher 应恒不命中")
}

@(test)
test_new_gitignore_matcher_skips_noise :: proc(t: ^testing.T) {
	alloc := context.allocator
	content := "# comment\n\n*.log\n   \nbuild/\n"
	m := new_gitignore_matcher(content, nil, alloc)
	defer destroy_gitignore_matcher(m, alloc)
	testing.expectf(t, len(m.patterns) == 2, "注释与空行应被跳过, 只剩 2 条, got %d", len(m.patterns))
	expect_str(t, m.patterns[0].pattern, "*.log", "第一条规则")
	testing.expect(t, m.patterns[1].dir_only, "第二条应为 dir_only")
}

// ---------------------------------------------------------------------------
// base
// ---------------------------------------------------------------------------

@(test)
test_is_default_skip_dir :: proc(t: ^testing.T) {
	should_skip := []string{".git", ".hg", ".svn", "node_modules", "vendor", "target", "build", ".idea", ".vscode"}
	for d in should_skip {
		testing.expectf(t, is_default_skip_dir(d), "%q 应默认跳过", d)
	}
	keep := []string{"", "src", "Build", "app", ".github"}
	for d in keep {
		testing.expectf(t, !is_default_skip_dir(d), "%q 不应默认跳过", d)
	}
	// 大小写敏感（APFS 默认不敏感，但匹配规则本身区分大小写）
	testing.expect(t, !is_default_skip_dir("Build"), "跳过表应大小写敏感")
}

@(test)
test_s2b_zero_copy :: proc(t: ^testing.T) {
	// 用可写缓冲（字符串字面量可能在只读段，写了会崩）
	src := "hello"
	buf := make([]u8, len(src), context.temp_allocator)
	copy(buf, src)
	s := string(buf)
	bs := s2b(s)
	testing.expect(t, len(bs) == len(s), "字节视图长度应与字符串一致")
	testing.expect(t, raw_data(bs[:]) == raw_data(s), "应与原字符串共享底层内存（零拷贝）")
	bs[0] = 'H'
	testing.expectf(t, s == "Hello", "写字节视图应反映到同一块内存, got %q", s)
}
