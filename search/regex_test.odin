package search

// ============================================================================
// regex_test.odin — 正则引擎测试
//
// 覆盖：
//   * 字面量快路径与 VM 路径结果一致（差分）
//   * 元字符 / 字符类 / 分组 / 交替 / 重复 / 锚点 / 大小写 / 反向引用
//   * FindAll 非重叠与空匹配语义
//   * ReplaceAll 的 $1/${1}/$$ 展开
//   * 错误模式的拒绝
// ============================================================================

import "core:fmt"
import "core:strings"
import "core:testing"

// 字符串 → []u8 视图（Odin 无 []u8("literal") 语法）。
b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// 收集全部匹配的 (start, end) 文本对，便于断言。
spans_text :: proc(re: ^Regex, data: string) -> (out: [dynamic]string, ok: bool) {
	ms, found := regex_find_all(re, b(data))
	defer regex_free_matches(re, &ms)
	if !found {
		return {}, false
	}
	for m in ms {
		append(&out, data[m.start:m.end])
	}
	return out, true
}

// 强制走 VM（禁用字面量快路径）后取匹配文本——与快路径做差分。
spans_text_vm :: proc(re: ^Regex, data: string) -> (out: [dynamic]string) {
	saved := re.literal
	re.literal = nil
	defer re.literal = saved
	ms, _ := regex_find_all(re, b(data))
	defer regex_free_matches(re, &ms)
	for m in ms {
		append(&out, data[m.start:m.end])
	}
	return out
}

expect_spans :: proc(t: ^testing.T, re: ^Regex, data: string, want: []string) {
	got, ok := spans_text(re, data)
	defer delete(got)
	testing.expect(t, ok, "find_all 应成功")
	testing.expectf(t, len(got) == len(want), "got %v want %v", got, want)
	if len(got) != len(want) {
		return
	}
	for i in 0..<len(got) {
		testing.expectf(t, got[i] == want[i], "match %d: got %q want %q", i, got[i], want[i])
	}
	// 差分：快路径与 VM 必须一致
	vm_got := spans_text_vm(re, data)
	defer delete(vm_got)
	testing.expectf(t, len(vm_got) == len(got), "VM 与快路径条数不一致: %v vs %v", vm_got, got)
	for i in 0..<min(len(vm_got), len(got)) {
		testing.expectf(t, vm_got[i] == got[i], "VM/快路径第 %d 条: %q vs %q", i, vm_got[i], got[i])
	}
}

compile_or_fail :: proc(t: ^testing.T, pattern: string, ci := false) -> ^Regex {
	re, ok := regex_compile(pattern, ci)
	testing.expectf(t, ok, "模式应编译成功: %q", pattern)
	return re
}

@(test)
test_literal :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "abc")
	defer regex_destroy(re)
	expect_spans(t, re, "xxabcyyabc", {"abc", "abc"})
	expect_spans(t, re, "no match here", {})
}

@(test)
test_meta_chars :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "a.c")
	defer regex_destroy(re)
	// Go: `.` 匹配含空格在内的任意字符（不含 \n）
	expect_spans(t, re, "abc a c axc", {"abc", "a c", "axc"})

	re2 := compile_or_fail(t, "a.*c")
	defer regex_destroy(re2)
	// Go: `.*` 贪婪，跨空格匹配到最后一个 c
	expect_spans(t, re2, "abcc aXYZc", {"abcc aXYZc"})
}

@(test)
test_classes :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "[a-c]+")
	defer regex_destroy(re)
	expect_spans(t, re, "abc abd d", {"abc", "ab"})

	re2 := compile_or_fail(t, "[^0-9]+")
	defer regex_destroy(re2)
	expect_spans(t, re2, "a1b22c", {"a", "b", "c"})

	re3 := compile_or_fail(t, `\d+`)
	defer regex_destroy(re3)
	expect_spans(t, re3, "a12b345", {"12", "345"})

	re4 := compile_or_fail(t, `\w+`)
	defer regex_destroy(re4)
	expect_spans(t, re4, "  foo_bar 12 ", {"foo_bar", "12"})

	re5 := compile_or_fail(t, `\s+`)
	defer regex_destroy(re5)
	// Go: "\t " 吃掉 tab+空格后，下一个 c 非空白，无单独 " " 匹配
	expect_spans(t, re5, "a  b\t c", {"  ", "\t "})
}

@(test)
test_alternation_and_groups :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "cat|dog")
	defer regex_destroy(re)
	expect_spans(t, re, "the cat and dog", {"cat", "dog"})

	re2 := compile_or_fail(t, "(ab)+")
	defer regex_destroy(re2)
	expect_spans(t, re2, "ababab x", {"ababab"})

	re3 := compile_or_fail(t, "(?:ab)+")
	defer regex_destroy(re3)
	expect_spans(t, re3, "abab x", {"abab"})
}

@(test)
test_repeat_bounds :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "a{2,3}")
	defer regex_destroy(re)
	expect_spans(t, re, "a aa aaaa", {"aa", "aaa"})

	re2 := compile_or_fail(t, "a{2}")
	defer regex_destroy(re2)
	expect_spans(t, re2, "a aa aaa", {"aa", "aa"})

	re3 := compile_or_fail(t, "ab{1,}c")
	defer regex_destroy(re3)
	expect_spans(t, re3, "ac abc abbc", {"abc", "abbc"})
}

@(test)
test_anchors :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "^abc")
	defer regex_destroy(re)
	expect_spans(t, re, "abc xabc", {"abc"})

	re2 := compile_or_fail(t, "abc$")
	defer regex_destroy(re2)
	expect_spans(t, re2, "abc xabc", {"abc"})

	re3 := compile_or_fail(t, `\bword\b`)
	defer regex_destroy(re3)
	expect_spans(t, re3, "a word words word", {"word", "word"})
}

@(test)
test_case_insensitive :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "hello", true)
	defer regex_destroy(re)
	expect_spans(t, re, "say HELLO to hello", {"HELLO", "hello"})

	re2 := compile_or_fail(t, "(?i)hello")
	defer regex_destroy(re2)
	expect_spans(t, re2, "HeLLo", {"HeLLo"})

	re3 := compile_or_fail(t, "(?i:[a-z])+")
	defer regex_destroy(re3)
	expect_spans(t, re3, "ABC def", {"ABC", "def"})
}

@(test)
test_empty_match :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "a*")
	defer regex_destroy(re)
	// Go: FindAllIndex("a*", "baa") → [0,0] [1,3]（结尾空匹配与上一匹配终点
	// 重合会被 allMatches 丢弃，故只有两条）
	expect_spans(t, re, "baa", {"", "aa"})

	re2 := compile_or_fail(t, "")
	defer regex_destroy(re2)
	expect_spans(t, re2, "ab", {"", "", ""})
}

@(test)
test_backref :: proc(t: ^testing.T) {
	// 注意：Go regexp 不支持反向引用（`\1` 直接编译错误），本引擎是超集。
	// 语义按左优先回溯（Perl/PCRE 风格）：(a+)\1 在 "aa aaaa aaa" 上，
	// "aa"→a+ 取 "aa" 后 \1 需 "aa" 命中；"aaa"→回溯到 a+="aa"+\1="a" 不可行，
	// 再回溯到 a+="a"+\1="a" → "aa"。
	re := compile_or_fail(t, `(a+)\1`)
	defer regex_destroy(re)
	expect_spans(t, re, "aa aaaa aaa", {"aa", "aaaa", "aa"})

	re2 := compile_or_fail(t, `(['"]).*\1`)
	defer regex_destroy(re2)
	expect_spans(t, re2, `say "hi" and 'yo'`, {`"hi"`, `'yo'`})
}

@(test)
test_lazy :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "a.*?c")
	defer regex_destroy(re)
	expect_spans(t, re, "abc aXcYc", {"abc", "aXc"})

	re2 := compile_or_fail(t, "<.+?>")
	defer regex_destroy(re2)
	expect_spans(t, re2, "<a><bb>", {"<a>", "<bb>"})
}

@(test)
test_replace :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "o")
	defer regex_destroy(re)
	out, changed := regex_replace_all(re, b("foo boo"), "0")
	defer delete(out)
	testing.expect(t, changed, "应发生替换")
	testing.expectf(t, string(out) == "f00 b00", "got %q", string(out))

	re2 := compile_or_fail(t, `(\w+)@(\w+)`)
	defer regex_destroy(re2)
	out2, _ := regex_replace_all(re2, b("user@host"), "$2:$1")
	defer delete(out2)
	testing.expectf(t, string(out2) == "host:user", "got %q", string(out2))

	re3 := compile_or_fail(t, `(\w+)@(\w+)`)
	defer regex_destroy(re3)
	out3, _ := regex_replace_all(re3, b("user@host"), "${2}_${1}")
	defer delete(out3)
	testing.expectf(t, string(out3) == "host_user", "got %q", string(out3))

	// $$ → 字面 $；未参与组 → 空
	re4 := compile_or_fail(t, "x(y)?z")
	defer regex_destroy(re4)
	out4, _ := regex_replace_all(re4, b("xz xyz"), "[$1$$]")
	defer delete(out4)
	testing.expectf(t, string(out4) == "[$] [y$]", "got %q", string(out4))
}

@(test)
test_invalid_patterns :: proc(t: ^testing.T) {
	bad := []string{
		"(",
		")",
		"[a-",
		"a{2,1}",
		`\9`,
		"*a",
	}
	for p in bad {
		_, ok := regex_compile(p, false)
		testing.expectf(t, !ok, "模式应被拒绝: %q", p)
	}
}

@(test)
test_brace_not_repeat :: proc(t: ^testing.T) {
	// `{` 后不是合法重复时按字面量处理（Go 行为）
	re := compile_or_fail(t, "a{b")
	defer regex_destroy(re)
	expect_spans(t, re, "a{b x", {"a{b"})
}

@(test)
test_matches_bool :: proc(t: ^testing.T) {
	re := compile_or_fail(t, "bc")
	defer regex_destroy(re)
	testing.expect(t, regex_matches(re, b("abcd")), "应命中")
	testing.expect(t, !regex_matches(re, b("acd")), "不应命中")

	// 非字面量模式也必须全文搜索（不能只锚定起点）
	re2 := compile_or_fail(t, "b.")
	defer regex_destroy(re2)
	testing.expect(t, regex_matches(re2, b("abc")), "中后段应命中")
	testing.expect(t, !regex_matches(re2, b("axc")), "不应命中")

	re3 := compile_or_fail(t, "^x")
	defer regex_destroy(re3)
	testing.expect(t, !regex_matches(re3, b("yx")), "锚点应拒绝")
}

@(test)
test_find_first_groups :: proc(t: ^testing.T) {
	re := compile_or_fail(t, `(\w+)=(\d+)`)
	defer regex_destroy(re)
	sample := "key=42"
	m, ok := regex_find_first(re, b(sample))
	defer if m.groups != nil {delete(m.groups, re.allocator)}
	testing.expect(t, ok, "应命中")
	testing.expectf(t, m.start == 0 && m.end == 6, "区间 %d..%d", m.start, m.end)
	testing.expectf(t, len(m.groups) == 6, "groups 长度 %d", len(m.groups))
	// groups[2..3] = 第一组 key
	testing.expectf(t, sample[m.groups[2]:m.groups[3]] == "key", "group1 %q", sample[m.groups[2]:m.groups[3]])
}

@(test)
test_nested_and_dense :: proc(t: ^testing.T) {
	// 病态但可完成的回溯：确保步数上限不会误伤正常模式
	re := compile_or_fail(t, "(a|a)*b")
	defer regex_destroy(re)
	expect_spans(t, re, "aaab", {"aaab"})

	re2 := compile_or_fail(t, "(a+)+b")
	defer regex_destroy(re2)
	expect_spans(t, re2, "aaab", {"aaab"})

	// 空转循环不得挂死（无进展裁剪）；Go: (a?)* on "aa" → ["aa"]
	// （结尾空匹配与上一匹配终点重合，被 allMatches 丢弃）
	re3 := compile_or_fail(t, "(a?)*")
	defer regex_destroy(re3)
	expect_spans(t, re3, "aa", {"aa"})
}

@(test)
test_quote_meta :: proc(t: ^testing.T) {
	// 元字符集与 Go regexp.QuoteMeta 完全一致（14 个）
	cases := []struct {
		src:  string,
		want: string,
	}{
		{"", ""},
		{"abc", "abc"},
		{"a.c", `a\.c`},
		{"[test]", `\[test\]`},
		{"a+b*c?", `a\+b\*c\?`},
		{"(x)|y", `\(x\)\|y`},
		{"{1,2}", `\{1,2\}`},
		{"^start$", `\^start\$`},
		{`back\slash`, `back\\slash`},
		{`a\db`, `a\\db`},
		{"mix.*+[](){}^$|?\\", `mix\.\*\+\[\]\(\)\{\}\^\$\|\?\\`},
	}
	for c in cases {
		got := regex_quote_meta(c.src)
		defer delete(got)
		testing.expectf(t, got == c.want, "quote_meta(%q) = %q, want %q", c.src, got, c.want)
	}

	// 转义后编译：元字符按字面量匹配（-F 语义）
	quoted := regex_quote_meta("[test]")
	defer delete(quoted)
	re := compile_or_fail(t, quoted)
	defer regex_destroy(re)
	testing.expect(t, regex_matches(re, b("value [test] here")), "字面量应命中")
	testing.expect(t, !regex_matches(re, b("plain test")), "无括号不应命中")

	// 反斜杠字面量：pattern `a\db` 经转义后匹配三字节 a \ d
	quoted2 := regex_quote_meta(`a\db`)
	defer delete(quoted2)
	re2 := compile_or_fail(t, quoted2)
	defer regex_destroy(re2)
	testing.expect(t, regex_matches(re2, b("xa\\dby")), "应命中 a\\db")
	testing.expect(t, !regex_matches(re2, b("a1b")), "不应按 \\d 数字类命中")
}

@(test)
test_replace_template_go_semantics :: proc(t: ^testing.T) {
	// 期望值全部由本机 Go 得到（re.ReplaceAllString("foo_one.txt", tmpl)）：
	//   "$2_$1" -> "foo.txt"（$2_ 是**名字** "2_"，不存在 → 空）
	//   "$12"   -> ".txt"  （12 号组越界 → 空，没有单数字回退）
	//   "${1"   -> "${1.txt"（缺右括号 → $ 原样）
	cases := []struct {
		tmpl: string,
		want: string,
	}{
		{"$2_$1", "foo.txt"},
		{"$12", ".txt"},
		{"${1}x", "foox.txt"},
		{"${1", "${1.txt"},
		{"$$", "$.txt"},
		{"$", "$.txt"},
		{"$0", "foo_one.txt"},
		{"$99", ".txt"},
		{"$2x", ".txt"},
		{"a$1b", "a.txt"},
		{"$01", ".txt"}, // 前导零 → 当名字 "01" → 查不到 → 空
		{"$1_$2", "one.txt"}, // 同上：名字 "1_" 不存在
		{"${2}${1}", "onefoo.txt"},
	}
	re := compile_or_fail(t, "(foo)_(one)")
	defer regex_destroy(re)
	data := b("foo_one.txt")
	for c in cases {
		out, _ := regex_replace_all(re, data, c.tmpl)
		got := string(out)
		testing.expectf(t, got == c.want, "tmpl %q: got %q want %q", c.tmpl, got, c.want)
		delete(out)
	}

	// 命名组展开：$name / ${name}；不存在 → 空
	ren := compile_or_fail(t, `(?P<year>\d{4})-(?P<mon>\d{2})`)
	defer regex_destroy(ren)
	for c in ([]struct {
		tmpl: string,
		want: string,
	}{{"$mon/$year", "10/2024"}, {"${year}", "2024"}, {"$nope", ""}}) {
		out, _ := regex_replace_all(ren, b("2024-10"), c.tmpl)
		got := string(out)
		testing.expectf(t, got == c.want, "named tmpl %q: got %q want %q", c.tmpl, got, c.want)
		delete(out)
	}

	// 空匹配插入：Go 的 "x*" 在 "abc" 上 → "-a-b-c-"
	re2 := compile_or_fail(t, "x*")
	defer regex_destroy(re2)
	out2, _ := regex_replace_all(re2, b("abc"), "-")
	testing.expectf(t, string(out2) == "-a-b-c-", `empty-match: got %q want "-a-b-c-"`, string(out2))
	delete(out2)
}

// ============================================================================
// 前导字面量跳过（vm 路径的起点优化）
// ============================================================================

@(test)
test_prefix_skip_matches_exhaustive :: proc(t: ^testing.T) {
	// 这些模式既不为纯字面量（拿不到 re.literal），又带前导字面串，
	// 是 prefix 优化的适用区。期望值按 Go Regular Expression 的
	// 左优先语义手算，且与"逐字节起点穷举"必须一致。
	cases := []struct {
		pat:  string,
		data: string,
		want: []string,
	}{
		{`foo\d+`, "xxfoo12yyfoo345zz", {"foo12", "foo345"}},
		{`ab.`, "1abXabYab", {"abX", "abY"}},
		{`ab.`, "abaab", {"aba"}},
		{`foo\d+`, "fo1 fo2 foo3", {"foo3"}},
		{`a+b`, "xaayaabzaabbb", {"aab", "aab"}},
		{`pre[a-z]*`, "PREstop preAlpha MID", {"pre"}},
		{`x[0-9]y`, "ax1ybx2y", {"x1y", "x2y"}},
		{`ab\d`, "", nil},
		{`ab\d`, "abz", nil},
		{`ab\d`, "aab1", {"ab1"}},
		{`ab\d`, "ab", nil}, // 前缀出现在末尾但不完整 → 无候选
		{`ab\d`, "aba", nil},
	}
	for c in cases {
		re := compile_or_fail(t, c.pat)
		if len(c.want) == 0 {
			// 期望无命中：find_all 应返回 found=false，且快路径/VM 一致
			got, ok := spans_text(re, c.data)
			testing.expectf(t, !ok || len(got) == 0, "%q on %q: 应无命中", c.pat, c.data)
			delete(got)
			regex_destroy(re)
			continue
		}
		expect_spans(t, re, c.data, c.want)
		regex_destroy(re)
	}
}

@(test)
test_prefix_skip_ci :: proc(t: ^testing.T) {
	// 大小写不敏感：前导串比较必须两端都折小写
	re := compile_or_fail(t, "Foo\\d+", true) // ignore_case=true
	defer regex_destroy(re)
	testing.expect(t, re.prefix != nil, "半字面 + ci 也应算出 prefix")
	expect_spans(t, re, "aaFOO7bbfoo88", {"FOO7", "foo88"})
}

@(test)
test_prefix_skip_anchored_and_meta_first :: proc(t: ^testing.T) {
	// 锚点/元字符开头不应拿到 prefix（保守边界）
	for pat in ([]string{`^ab\d`, `\dab`, `[a-z]ab\d`, `(ab)\d`, `(ab|cd)\d`, `a?ab\d`}) {
		re := compile_or_fail(t, pat)
		testing.expectf(t, re.prefix == nil, "%q 不应算出 prefix（保守放弃）", pat)
		regex_destroy(re)
	}
	// 但这些模式本身的行为必须仍然正确
	re := compile_or_fail(t, `^ab\d`)
	expect_spans(t, re, "ab1", {"ab1"})
	regex_destroy(re)
	re2 := compile_or_fail(t, `a?ab\d`)
	expect_spans(t, re2, "b1ab2", {"ab2"})
	regex_destroy(re2)
}

@(test)
test_prefix_skip_long_line :: proc(t: ^testing.T) {
	// 长输入：命中很少但可能起点很多 —— 同时测性能与结果正确性。
	// 构造 "..."*N + "needle9" + "..."*N，候选起点只有一处。
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for _ in 0..<4000 {
		strings.write_byte(&b, '.')
	}
	strings.write_string(&b, "needle9")
	for _ in 0..<4000 {
		strings.write_byte(&b, '.')
	}
	data := strings.to_string(b)
	re := compile_or_fail(t, `needle\d`)
	defer regex_destroy(re)
	testing.expect(t, re.prefix != nil, "应算出 prefix")
	expect_spans(t, re, data, {"needle9"})
}
