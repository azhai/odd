package app

// ============================================================================
// expr_test.odin — script 的迷你表达式引擎单测
//
// 为什么补：expr.odin 是仓库里最大的单文件（1200+ 行），此前零单测，只能靠
// 差分矩阵里 29 条 script 用例间接覆盖。差分一次只能喂一个脚本文件，覆盖不到
// "运算符优先级 / 短路求值 / 参数个数校验 / 报错路径"这些分支。
//
// 内存约定：解析出来的 AST（^Expr / ^Stmt 及其动态数组）没有 destroy 入口，
// 全靠分配器整体回收。测试里一律在开头把 context.allocator 指向
// context.temp_allocator —— 测试运行器会在单条测试结束后统一 free_all，
// 既不漏也不必手工逐个释放。
// ============================================================================

import "core:testing"

// 跑一段脚本源码，返回 __out 的最终值（未赋值 → Undef）与首个错误。
// err 非空时调用方应视为失败。
run_src :: proc(src: string) -> (Val, string) {
	prog, perr := parse_program(src)
	if perr != "" {
		return val_undef(), perr
	}
	env := Env{vars = make(map[string]Val, context.temp_allocator)}
	if err := exec_program(&env, prog); err != "" {
		return val_undef(), err
	}
	return env.vars["__out"], ""
}

// 断言值：同时比对 kind 与展示文本（display 文本就是差分比对的实际输出）。
expect_val :: proc(t: ^testing.T, v: Val, want_kind: Val_Kind, want_display: string, ctx: string) {
	testing.expectf(t, v.kind == want_kind, "%s: kind got %v want %v", ctx, v.kind, want_kind)
	got := val_display(v)
	testing.expectf(t, got == want_display, "%s: got %q want %q", ctx, got, want_display)
}

// 期望失败的脚本：err 必须非空。
expect_err :: proc(t: ^testing.T, src: string) {
	_, err := run_src(src)
	testing.expectf(t, err != "", "%s: 应报错", src)
}

// ---------------------------------------------------------------------------
// 值与工具函数
// ---------------------------------------------------------------------------

@(test)
test_val_helpers :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// Tengo 的 IsFalsy：undefined / false / 0 / "" 为假
	testing.expect(t, !val_truthy(val_undef()), "undefined 为假")
	testing.expect(t, !val_truthy(val_bool(false)), "false 为假")
	testing.expect(t, val_truthy(val_bool(true)), "true 为真")
	testing.expect(t, !val_truthy(val_int(0)), "0 为假")
	testing.expect(t, val_truthy(val_int(-1)), "-1 为真")
	testing.expect(t, !val_truthy(val_float(0)), "0.0 为假")
	testing.expect(t, val_truthy(val_float(0.5)), "0.5 为真")
	testing.expect(t, !val_truthy(val_str("")), `"" 为假`)
	testing.expect(t, val_truthy(val_str("x")), `"x" 为真`)

	expect_val(t, val_int(42), .Int, "42", "val_display int")
	expect_val(t, val_float(1.5), .Float, "1.5", "val_display float")
	expect_val(t, val_bool(true), .Bool, "true", "val_display bool")
	expect_val(t, val_bool(false), .Bool, "false", "val_display false")
	expect_val(t, val_undef(), .Undef, "", "val_display undefined")
	expect_val(t, val_str("abc"), .Str, "abc", "val_display string")

	f, is_int, ok := val_number(val_int(7))
	testing.expect(t, ok && is_int && f == 7, "int → number")
	_, is_int2, ok2 := val_number(val_float(7))
	testing.expect(t, ok2 && !is_int2, "float → number 且 is_int=false")
	_, _, ok3 := val_number(val_str("x"))
	testing.expect(t, !ok3, "string 不是 number")
}

@(test)
test_split_qualified :: proc(t: ^testing.T) {
	m1, f1 := split_qualified("text.to_upper")
	testing.expect(t, m1 == "text" && f1 == "to_upper", "带点的限定名应拆分")
	m2, f2 := split_qualified("sprintf")
	testing.expect(t, m2 == "" && f2 == "sprintf", "不带点则模块为空")
	m3, f3 := split_qualified("a.b.c")
	testing.expect(t, m3 == "a.b" && f3 == "c", "多级以最后一个点为界")
}

@(test)
test_unescape_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect(t, unescape_string("plain") == "plain", "无转义序列应原样返回")
	testing.expect(t, unescape_string(`a\nb`) == "a\nb", `\n → 换行`)
	testing.expect(t, unescape_string(`a\tb`) == "a\tb", `\t → 制表符`)
	testing.expect(t, unescape_string(`a\\b`) == `a\b`, `\\ → 单个反斜杠`)
	testing.expect(t, unescape_string(`a\"b`) == `a"b`, `\" → 双引号`)
	testing.expect(t, unescape_string("") == "", "空串")
}

// ---------------------------------------------------------------------------
// 表达式求值
// ---------------------------------------------------------------------------

@(test)
test_expr_arithmetic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, e1 := run_src(`__out := 1 + 2 * 3`)
	testing.expectf(t, e1 == "", "不该报错, got %q", e1)
	expect_val(t, v1, .Int, "7", "乘法优先于加法")

	v2, _ := run_src(`__out := (1 + 2) * 3`)
	expect_val(t, v2, .Int, "9", "括号提升优先级")

	v3, _ := run_src(`__out := 10 - 3 - 2`)
	expect_val(t, v3, .Int, "5", "减法左结合")

	v4, _ := run_src(`__out := -5 + 2`)
	expect_val(t, v4, .Int, "-3", "一元负号")

	v5, _ := run_src(`__out := 1.5 + 2`)
	expect_val(t, v5, .Float, "3.5", "浮点提升")
}

@(test)
test_expr_int_and_float_division :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, _ := run_src(`__out := 7 / 2`)
	expect_val(t, v1, .Int, "3", "整数除法截断")

	v2, _ := run_src(`__out := 7 % 3`)
	expect_val(t, v2, .Int, "1", "取模")

	v3, _ := run_src(`__out := 7.0 / 2`)
	expect_val(t, v3, .Float, "3.5", "浮点除法")

	_, err_div0 := run_src(`__out := 1 / 0`)
	testing.expect(t, err_div0 != "", "整数除零应报错")
	_, err_mod0 := run_src(`__out := 1 % 0`)
	testing.expect(t, err_mod0 != "", "整数取模零应报错")
	_, err_fdiv0 := run_src(`__out := 1.0 / 0`)
	testing.expect(t, err_fdiv0 != "", "浮点除零应报错")
	_, err_fmod := run_src(`__out := 1.5 % 0.5`)
	testing.expect(t, err_fmod != "", "浮点取模应报错（要求整数）")
}

@(test)
test_expr_string_ops :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, _ := run_src(`__out := "ab" + "cd"`)
	expect_val(t, v1, .Str, "abcd", "字符串加号拼接")

	v2, _ := run_src(`__out := "abc" < "abd"`)
	expect_val(t, v2, .Bool, "true", "字符串按字典序比较")

	v3, _ := run_src(`__out := "abc" == "abc"`)
	expect_val(t, v3, .Bool, "true", "字符串相等")

	// 字符串与数字相加应当报错（不允许隐式转换）
	_, err := run_src(`__out := "a" + 1`)
	testing.expect(t, err != "", "字符串与数字相加应报错")
}

@(test)
test_expr_logic_short_circuit :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, _ := run_src(`__out := 1 < 2 && 3 < 4`)
	expect_val(t, v1, .Bool, "true", "&& 两侧为真")

	v2, _ := run_src(`__out := 1 > 2 && 3 < 4`)
	expect_val(t, v2, .Bool, "false", "&& 左侧为假")

	v3, _ := run_src(`__out := 1 > 2 || 3 < 4`)
	expect_val(t, v3, .Bool, "true", "|| 右侧为真")

	// 短路：右侧的未定义变量不该被求值 → 不报错
	v4, err4 := run_src(`__out := 0 && nope`)
	testing.expectf(t, err4 == "", "&& 左侧为假时应短路, got %q", err4)
	expect_val(t, v4, .Bool, "false", "&& 短路结果")

	v5, err5 := run_src(`__out := 1 || nope`)
	testing.expectf(t, err5 == "", "|| 左侧为真时应短路, got %q", err5)
	expect_val(t, v5, .Bool, "true", "|| 短路结果")

	// 不短路时未定义变量仍然报错
	expect_err(t, `__out := 1 && nope`)
}

@(test)
test_expr_ternary :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, _ := run_src(`__out := 1 < 2 ? "yes" : "no"`)
	expect_val(t, v1, .Str, "yes", "条件为真取 then 分支")

	v2, _ := run_src(`__out := 1 > 2 ? "yes" : "no"`)
	expect_val(t, v2, .Str, "no", "条件为假取 else 分支")

	// 右结合：a ? b : c ? d : e
	v3, err3 := run_src(`__out := false ? "a" : true ? "b" : "c"`)
	testing.expectf(t, err3 == "", "三元嵌套不该报错, got %q", err3)
	expect_val(t, v3, .Str, "b", "三元右结合")
}

// ---------------------------------------------------------------------------
// 内建函数与模块
// ---------------------------------------------------------------------------

@(test)
test_builtin_functions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v1, _ := run_src(`__out := len("hello")`)
	expect_val(t, v1, .Int, "5", "len 字符串")

	v2, _ := run_src(`__out := string(42)`)
	expect_val(t, v2, .Str, "42", "string 转换")

	v3, _ := run_src(`__out := int("42")`)
	expect_val(t, v3, .Int, "42", "int 转换")

	// import 在 odd 里是空绑定（返回空串），只为让 gx 风格脚本原样跑通
	v4, err4 := run_src(`text := import("text")
__out := text.to_upper("ab")`)
	testing.expectf(t, err4 == "", "import 后调用模块函数不该报错, got %q", err4)
	expect_val(t, v4, .Str, "AB", "import 空绑定后仍可调用 text.*")

	expect_err(t, `__out := undefined_fn(1)`)
	expect_err(t, `__out := len("a", "b")`)
	expect_err(t, `__out := len(1)`)
}

@(test)
test_text_functions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := []struct {
		src:  string,
		want: string,
	}{
		{`__out := text.to_upper("aBc")`, "ABC"},
		{`__out := text.to_lower("aBc")`, "abc"},
		{`__out := text.trim_space("  x  ")`, "x"},
		{`__out := text.trim("xxaxx", "x")`, "a"},
		{`__out := text.trim_prefix("foobar", "foo")`, "bar"},
		{`__out := text.trim_suffix("foobar", "bar")`, "foo"},
		{`__out := text.index("foobar", "ba")`, "3"},
		{`__out := text.repeat("ab", 3)`, "ababab"},
		{`__out := text.itoa(123)`, "123"},
		{`__out := text.atoi("456")`, "456"},
		{`__out := text.atoi("notanum")`, "0"}, // Tengo 的 atoi 失败返回 0
	}
	for c in cases {
		v, err := run_src(c.src)
		testing.expectf(t, err == "", "%s: 不该报错, got %q", c.src, err)
		testing.expectf(t, val_display(v) == c.want, "%s: got %q want %q", c.src, val_display(v), c.want)
	}

	// 布尔返回的函数
	v1, _ := run_src(`__out := text.contains("foobar", "oob")`)
	expect_val(t, v1, .Bool, "true", "contains 命中")
	v2, _ := run_src(`__out := text.has_prefix("foobar", "foo")`)
	expect_val(t, v2, .Bool, "true", "has_prefix")
	v3, _ := run_src(`__out := text.has_suffix("foobar", "xyz")`)
	expect_val(t, v3, .Bool, "false", "has_suffix 未命中")
}

@(test)
test_text_replace_and_regex :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	// 4 参 replace：最后一个参数是次数，负数 = 全部替换
	v1, _ := run_src(`__out := text.replace("aaa", "a", "b", -1)`)
	expect_val(t, v1, .Str, "bbb", "replace 全部")
	v2, _ := run_src(`__out := text.replace("aaa", "a", "b", 1)`)
	expect_val(t, v2, .Str, "baa", "replace 限次")

	v3, _ := run_src(`__out := text.re_match("^a.*c$", "abc")`)
	expect_val(t, v3, .Bool, "true", "re_match 命中")
	v4, _ := run_src(`__out := text.re_match("^d", "abc")`)
	expect_val(t, v4, .Bool, "false", "re_match 未命中")

	v5, _ := run_src(`__out := text.re_replace("a+", "aaabaa", "X")`)
	expect_val(t, v5, .Str, "XbX", "re_replace 全部替换")

	// 模板展开：$1
	v6, _ := run_src(`__out := text.re_replace("(\\w+)@(\\w+)", "me@home", "$2:$1")`)
	expect_val(t, v6, .Str, "home:me", "re_replace 的组引用")

	expect_err(t, `__out := text.re_match("[", "abc")`)
}

@(test)
test_sprintf :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cases := []struct {
		src:  string,
		want: string,
	}{
		{`__out := fmt.sprintf("%s", "a")`, "a"},
		{`__out := fmt.sprintf("%d", 42)`, "42"},
		{`__out := fmt.sprintf("%d-%s", 1, "x")`, "1-x"},
		{`__out := fmt.sprintf("100%%")`, "100%"},
		{`__out := fmt.sprintf("%03d", 1)`, "001"}, // 宽度+零填充（一度与 gx 不一致）
		{`__out := fmt.sprintf("%-5s|", "ab")`, "ab   |"}, // 左对齐
		{`__out := fmt.sprintf("%5s|", "ab")`, "   ab|"}, // 右对齐
		{`__out := fmt.sprintf("%q", "x")`, `"x"`},
	}
	for c in cases {
		v, err := run_src(c.src)
		testing.expectf(t, err == "", "%s: 不该报错, got %q", c.src, err)
		testing.expectf(t, val_display(v) == c.want, "%s: got %q want %q", c.src, val_display(v), c.want)
	}

	// 尾随 % 不打描述符时原样输出
	v, _ := run_src(`__out := fmt.sprintf("ab%")`)
	testing.expect(t, val_display(v) == "ab%", "尾随 % 应原样输出")

	// 参数不足报错
	expect_err(t, `__out := fmt.sprintf("%d %d", 1)`)
}

// ---------------------------------------------------------------------------
// 语句执行
// ---------------------------------------------------------------------------

@(test)
test_script_assign_and_if :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	v, err := run_src(`
x := 1 + 1
if x > 1 {
  __out := "big"
} else {
  __out := "small"
}`)
	testing.expectf(t, err == "", "if/else 脚本不该报错, got %q", err)
	expect_val(t, v, .Str, "big", "if 分支应执行")

	v2, err2 := run_src(`
x := 0
if x > 1 {
  __out := "big"
} else {
  __out := "small"
}`)
	testing.expectf(t, err2 == "", "else 脚本不该报错, got %q", err2)
	expect_val(t, v2, .Str, "small", "else 分支应执行")

	// 变量跨语句可见（同一 Env）
	v3, err3 := run_src(`
a := "foo"
b := "bar"
__out := a + b`)
	testing.expectf(t, err3 == "", "多语句不该报错, got %q", err3)
	expect_val(t, v3, .Str, "foobar", "跨语句变量可见")
}

@(test)
test_script_runtime_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expect_err(t, `__out := nope`) // 未定义变量
	expect_err(t, `x := 1
__out := x + y`) // 第二条语句报错应中断执行
	expect_err(t, `__out := (1 + 2`) // 括号不闭合 → 解析错误
	expect_err(t, `__out := "unterminated`) // 字符串不闭合
	expect_err(t, `__out := nosuchmod.fn(1)`) // 未知模块
	expect_err(t, `__out := text.nosuchfn(1)`) // 未知函数
}
