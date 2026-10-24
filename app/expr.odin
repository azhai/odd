package app

// ============================================================================
// expr.odin — script 子命令的迷你表达式引擎（gx 用 Tengo，这里是有界子集）
//
// 为什么不是完整 Tengo：Tengo 是完整的嵌入式脚本语言（AST + VM + 标准库），
// 用 Odin 复刻其全部语义不现实。这里实现 sed/awk 风格任务真正需要的子集，
// 并**明确报错**（而不是静默出错）当脚本用了子集之外的语法/函数。
//
// 支持的语法
//   字面量     42  3.14  "str"  `raw`  true  false
//   变量       line lineno filename content __out（以及用户赋值过的名字）
//   运算符     一元 ! -，二元 + - * / % == != < <= > >= && ||，三元 ?:
//   调用       name(args) / mod.func(args)（暂不支持方法调用与数组/映射）
//   语句（-f） name := expr / name = expr / 表达式语句 / if cond { } else { }
//   注释       // 到行尾
//
// 支持的函数（gx 的 safeModules 里与本引擎能力对应的部分）
//   内置        len(s) string(v) int(v)
//   text.*      to_upper to_lower trim_space trim trim_prefix trim_suffix
//               contains has_prefix has_suffix index repeat replace
//               atoi itoa re_match re_replace
//   fmt.*       sprintf（%s %d %v %q %% 顺序替换）
//
// 与 Tengo 的语义差异（README 记录）
//   * 没有数组/映射/闭包/for/switch，无 os/exec 等模块（--unsafe 仅占位）
//   * 数值只有 int(i64) 与 float(f64)；int/int 除法向零截断
//   * 字符串拼接只允许 string + string（Tengo 同），其它类型组合报错
//   * --timeout 不中断执行（引擎无循环可挂起），仅保留参数兼容
// ============================================================================

import "core:fmt"
import "core:strconv"
import "core:strings"
import "odd:search"

// ---------------------------------------------------------------------------
// 词法
// ---------------------------------------------------------------------------

Tok_Kind :: enum {
	EOF,
	IDENT,
	INT,
	FLOAT,
	STR,
	PUNCT,
}

Token :: struct {
	kind: Tok_Kind,
	text: string, // IDENT/PUNCT 原文；STR 为已去引号的原文（转义未处理）
	pos:  int,
}

Lexer :: struct {
	src: string,
	pos: int,
	err: string, // 词法错误（目前只有"字符串未闭合"）；非空后不再产出有效 token
}

lex_error :: proc(lx: ^Lexer, msg: string) -> string {
	return fmt.aprintf("syntax error at byte %d: %s", lx.pos, msg)
}

// 跳到下一个 token；无法识别时返回 PUNCT + 空 text（调用方判错）。
lex_next :: proc(lx: ^Lexer) -> Token {
	// 空白与注释
	for lx.pos < len(lx.src) {
		c := lx.src[lx.pos]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			lx.pos += 1
			continue
		}
		if c == '/' && lx.pos + 1 < len(lx.src) && lx.src[lx.pos + 1] == '/' {
			for lx.pos < len(lx.src) && lx.src[lx.pos] != '\n' {
				lx.pos += 1
			}
			continue
		}
		break
	}
	if lx.pos >= len(lx.src) {
		return Token{kind = .EOF, pos = lx.pos}
	}

	start := lx.pos
	c := lx.src[lx.pos]

	// 标识符/关键字
	if is_ident_start(c) {
		lx.pos += 1
		for lx.pos < len(lx.src) && is_ident_char(lx.src[lx.pos]) {
			lx.pos += 1
		}
		return Token{kind = .IDENT, text = lx.src[start:lx.pos], pos = start}
	}

	// 数字
	if c >= '0' && c <= '9' {
		is_float := false
		lx.pos += 1
		for lx.pos < len(lx.src) && lx.src[lx.pos] >= '0' && lx.src[lx.pos] <= '9' {
			lx.pos += 1
		}
		if lx.pos < len(lx.src) && lx.src[lx.pos] == '.' && lx.pos + 1 < len(lx.src) && lx.src[lx.pos + 1] >= '0' && lx.src[lx.pos + 1] <= '9' {
			is_float = true
			lx.pos += 1
			for lx.pos < len(lx.src) && lx.src[lx.pos] >= '0' && lx.src[lx.pos] <= '9' {
				lx.pos += 1
			}
		}
		kind := Tok_Kind.INT
		if is_float {
			kind = .FLOAT
		}
		return Token{kind = kind, text = lx.src[start:lx.pos], pos = start}
	}

	// 字符串：双引号（支持 \\ \" \n \t \r）或反引号（原样）
	if c == '"' || c == '`' {
		quote := c
		lx.pos += 1
		body_start := lx.pos
		for lx.pos < len(lx.src) {
			ch := lx.src[lx.pos]
			if ch == '\\' && quote == '"' && lx.pos + 1 < len(lx.src) {
				lx.pos += 2
				continue
			}
			if ch == quote {
				body := lx.src[body_start:lx.pos]
				lx.pos += 1
				return Token{kind = .STR, text = body, pos = start}
			}
			lx.pos += 1
		}
		// 跑到源尾也没闭合：这是**错误**，不是空串。
		// 早前返回 `Token{.STR, text="", ...}` 让上层把它当成合法空串，
		// `__out := "unterminated` 于是静默成功（gx 在同输入下报
		// "Parse Error: expected ')'..."，退出码 2）——单测把它抓了出来。
		lx.err = lex_error(lx, "unterminated string literal")
		return Token{kind = .EOF, pos = start}
	}

	// 多字符运算符
	if lx.pos + 1 < len(lx.src) {
		two := lx.src[lx.pos:lx.pos + 2]
		switch two {
		case "==", "!=", "<=", ">=", "&&", "||", ":=":
			lx.pos += 2
			return Token{kind = .PUNCT, text = two, pos = start}
		}
	}

	switch c {
	case '+', '-', '*', '/', '%', '<', '>', '!', '?', ':', '(', ')', '{', '}', ',', '=', '.':
		lx.pos += 1
		return Token{kind = .PUNCT, text = lx.src[start:lx.pos], pos = start}
	}

	lx.pos += 1
	return Token{kind = .PUNCT, text = "", pos = start} // 未知字符
}

is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

is_ident_char :: proc(c: u8) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9')
}

// ---------------------------------------------------------------------------
// 值
// ---------------------------------------------------------------------------

Val_Kind :: enum {
	Undef,
	Str,
	Int,
	Float,
	Bool,
}

Val :: struct {
	kind: Val_Kind,
	s:    string,
	i:    i64,
	f:    f64,
	b:    bool,
}

val_str :: proc(s: string) -> Val {return Val{kind = .Str, s = s}}
val_int :: proc(i: i64) -> Val {return Val{kind = .Int, i = i}}
val_float :: proc(f: f64) -> Val {return Val{kind = .Float, f = f}}
val_bool :: proc(b: bool) -> Val {return Val{kind = .Bool, b = b}}
val_undef :: proc() -> Val {return Val{kind = .Undef}}

// Tengo 的 IsFalsy：undefined / false / 0 / "" 为假。
val_truthy :: proc(v: Val) -> bool {
	switch v.kind {
	case .Undef:
		return false
	case .Bool:
		return v.b
	case .Int:
		return v.i != 0
	case .Float:
		return v.f != 0
	case .Str:
		return len(v.s) > 0
	}
	return false
}

// val_display — 结果写出的文本（gx 用 fmt.Sprint，bool 走 String()）。
val_display :: proc(v: Val) -> string {
	switch v.kind {
	case .Str:
		return v.s
	case .Int:
		return fmt.aprintf("%d", v.i)
	case .Float:
		return fmt.aprintf("%v", v.f)
	case .Bool:
		return "true" if v.b else "false"
	case .Undef:
		return ""
	}
	return ""
}

val_number :: proc(v: Val) -> (f: f64, is_int: bool, ok: bool) {
	#partial switch v.kind {
	case .Int:
		return f64(v.i), true, true
	case .Float:
		return v.f, false, true
	}
	return 0, false, false
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

Expr_Kind :: enum {
	Lit,
	Var,
	Call,
	Unary,
	Binary,
	Ternary,
}

Expr :: struct {
	kind: Expr_Kind,
	val:  Val,
	name: string, // Var 名 / Call 全名（可含 '.'）
	op:   string,
	kids: [dynamic]^Expr,
}

Stmt_Kind :: enum {
	Assign,
	Expr_Stmt,
	If,
}

Stmt :: struct {
	kind: Stmt_Kind,
	name: string, // Assign 目标
	expr: ^Expr, // Assign 值 / Expr_Stmt 表达式
	cond: ^Expr, // If 条件
	then_body: [dynamic]^Stmt,
	else_body: [dynamic]^Stmt,
}

Program :: struct {
	stmts: [dynamic]^Stmt,
}

// ---------------------------------------------------------------------------
// 语法分析
// ---------------------------------------------------------------------------

Parser :: struct {
	lx:     ^Lexer,
	tok:    Token,
	peeked: bool,
	err:    string,
}

parse_error :: proc(p: ^Parser, msg: string) -> bool {
	if p.err == "" {
		p.err = fmt.aprintf("syntax error: %s (byte %d)", msg, p.tok.pos)
	}
	return false
}

advance :: proc(p: ^Parser) {
	p.tok = lex_next(p.lx)
	p.peeked = false
	// 词法错误在这里升级成解析错误，parse_program 会带着它返回。
	if p.err == "" && p.lx.err != "" {
		p.err = p.lx.err
	}
}

// 断点：解析失败返回 nil 并已在 p.err 里留下原因
parse_expression :: proc(p: ^Parser) -> (^Expr, bool) {
	return parse_binary(p, 1)
}

binary_prec :: proc(op: string) -> int {
	switch op {
	case "||":
		return 1
	case "&&":
		return 2
	case "==", "!=":
		return 3
	case "<", "<=", ">", ">=":
		return 4
	case "+", "-":
		return 5
	case "*", "/", "%":
		return 6
	}
	return 0
}

parse_binary :: proc(p: ^Parser, min_prec: int) -> (^Expr, bool) {
	left, ok := parse_unary(p)
	if !ok {
		return nil, false
	}
	for {
		op := ""
		if p.tok.kind == .PUNCT {
			op = p.tok.text
		}
		prec := binary_prec(op)
		if prec == 0 || prec < min_prec {
			break
		}
		advance(p)
		right, rok := parse_binary(p, prec + 1)
		if !rok {
			return nil, false
		}
		node := new(Expr)
		node.kind = .Binary
		node.op = op
		append(&node.kids, left, right)
		left = node
	}
	// 三元（右结合，优先级低于所有二元）
	if p.tok.kind == .PUNCT && p.tok.text == "?" && min_prec <= 1 {
		advance(p)
		then_e, tok_ok := parse_expression(p)
		if !tok_ok {
			return nil, false
		}
		if !(p.tok.kind == .PUNCT && p.tok.text == ":") {
			return nil, parse_error(p, `expected ":" in ternary`)
		}
		advance(p)
		else_e, eok := parse_expression(p)
		if !eok {
			return nil, false
		}
		node := new(Expr)
		node.kind = .Ternary
		append(&node.kids, left, then_e, else_e)
		left = node
	}
	return left, true
}

parse_unary :: proc(p: ^Parser) -> (^Expr, bool) {
	if p.tok.kind == .PUNCT && (p.tok.text == "!" || p.tok.text == "-") {
		op := p.tok.text
		advance(p)
		operand, ok := parse_unary(p)
		if !ok {
			return nil, false
		}
		node := new(Expr)
		node.kind = .Unary
		node.op = op
		append(&node.kids, operand)
		return node, true
	}
	return parse_primary(p)
}

parse_primary :: proc(p: ^Parser) -> (^Expr, bool) {
	#partial switch p.tok.kind {
	case .INT:
		v, ok := strconv.parse_i64(p.tok.text)
		if !ok {
			return nil, parse_error(p, "bad integer literal")
		}
		advance(p)
		node := new(Expr)
		node.kind = .Lit
		node.val = val_int(v)
		return node, true
	case .FLOAT:
		f, fok := strconv.parse_f64(p.tok.text)
		if !fok {
			return nil, parse_error(p, "bad float literal")
		}
		advance(p)
		node := new(Expr)
		node.kind = .Lit
		node.val = val_float(f)
		return node, true
	case .STR:
		raw := p.tok.text
		advance(p)
		// 双引号串在此做转义还原（反引号串原样，但词法阶段无法区分，统一按转义处理）
		node := new(Expr)
		node.kind = .Lit
		node.val = val_str(unescape_string(raw))
		return node, true
	case .IDENT:
		name := p.tok.text
		advance(p)
		// 关键字字面量
		switch name {
		case "true":
			node := new(Expr)
			node.kind = .Lit
			node.val = val_bool(true)
			return node, true
		case "false":
			node := new(Expr)
			node.kind = .Lit
			node.val = val_bool(false)
			return node, true
		case "undefined", "nil":
			node := new(Expr)
			node.kind = .Lit
			node.val = val_undef()
			return node, true
		}
		// 限定名 mod.func（只允许一层，够 text.* / fmt.* 用）
		for p.tok.kind == .PUNCT && p.tok.text == "." {
			advance(p)
			if p.tok.kind != .IDENT {
				return nil, parse_error(p, "expected identifier after \".\"")
			}
			name = fmt.aprintf("%s.%s", name, p.tok.text)
			advance(p)
		}
		if p.tok.kind == .PUNCT && p.tok.text == "(" {
			advance(p)
			node := new(Expr)
			node.kind = .Call
			node.name = name
			for {
				if p.tok.kind == .PUNCT && p.tok.text == ")" {
					break
				}
				arg, aok := parse_expression(p)
				if !aok {
					return nil, false
				}
				append(&node.kids, arg)
				if p.tok.kind == .PUNCT && p.tok.text == "," {
					advance(p)
					continue
				}
				break
			}
			if !(p.tok.kind == .PUNCT && p.tok.text == ")") {
				return nil, parse_error(p, `expected ")" after arguments`)
			}
			advance(p)
			return node, true
		}
		node := new(Expr)
		node.kind = .Var
		node.name = name
		return node, true
	case .PUNCT:
		if p.tok.text == "(" {
			advance(p)
			inner, ok := parse_expression(p)
			if !ok {
				return nil, false
			}
			if !(p.tok.kind == .PUNCT && p.tok.text == ")") {
				return nil, parse_error(p, `expected ")"`)
			}
			advance(p)
			return inner, true
		}
	}
	return nil, parse_error(p, fmt.aprintf("unexpected token %q", p.tok.text))
}

// 双引号串的转义还原：\\ \" \n \r \t \0；未知转义原样保留反斜杠。
unescape_string :: proc(s: string) -> string {
	if !strings.contains_rune(s, '\\') {
		return s
	}
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 'r':
				strings.write_byte(&b, '\r')
			case 't':
				strings.write_byte(&b, '\t')
			case '0':
				strings.write_byte(&b, 0)
			case '\\':
				strings.write_byte(&b, '\\')
			case '"':
				strings.write_byte(&b, '"')
			case:
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, s[i + 1])
			}
			i += 2
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}

// parse_statement — -f 脚本的语句集：赋值 / if / 表达式。
parse_statement :: proc(p: ^Parser) -> (^Stmt, bool) {
	if p.tok.kind == .PUNCT && p.tok.text == ";" {
		advance(p)
		return nil, true // 空语句
	}
	if p.tok.kind == .IDENT && p.tok.text == "if" {
		advance(p)
		cond, cok := parse_expression(p)
		if !cok {
			return nil, false
		}
		then_body, tok := parse_block(p)
		if !tok {
			return nil, false
		}
		node := new(Stmt)
		node.kind = .If
		node.cond = cond
		node.then_body = then_body
		// else / else if
		if p.tok.kind == .IDENT && p.tok.text == "else" {
			advance(p)
			if p.tok.kind == .IDENT && p.tok.text == "if" {
				inner, iok := parse_statement(p)
				if !iok {
					return nil, false
				}
				if inner != nil {
					append(&node.else_body, inner)
				}
			} else {
				body, bok := parse_block(p)
				if !bok {
					return nil, false
				}
				node.else_body = body
			}
		}
		return node, true
	}

	// name := expr / name = expr
	if p.tok.kind == .IDENT {
		name := p.tok.text
		// 预读一个 token 判断是否赋值（peek 通过保存状态实现）
		saved_pos := p.lx.pos
		saved_tok := p.tok
		advance(p)
		if p.tok.kind == .PUNCT && (p.tok.text == ":=" || p.tok.text == "=") {
			advance(p)
			value, vok := parse_expression(p)
			if !vok {
				return nil, false
			}
			node := new(Stmt)
			node.kind = .Assign
			node.name = name
			node.expr = value
			return node, true
		}
		// 不是赋值：回退到标识符，按表达式解析
		p.lx.pos = saved_pos
		p.tok = saved_tok
	}

	expr, eok := parse_expression(p)
	if !eok {
		return nil, false
	}
	node := new(Stmt)
	node.kind = .Expr_Stmt
	node.expr = expr
	return node, true
}

parse_block :: proc(p: ^Parser) -> ([dynamic]^Stmt, bool) {
	body: [dynamic]^Stmt
	if !(p.tok.kind == .PUNCT && p.tok.text == "{") {
		return body, parse_error(p, `expected "{"`)
	}
	advance(p)
	for {
		if p.tok.kind == .EOF {
			return body, parse_error(p, `expected "}"`)
		}
		if p.tok.kind == .PUNCT && p.tok.text == "}" {
			advance(p)
			return body, true
		}
		st, ok := parse_statement(p)
		if !ok {
			return body, false
		}
		if st != nil {
			append(&body, st)
		}
	}
}

// parse_program — 解析整段脚本（-f）或单表达式（-e）。
parse_program :: proc(src: string) -> (prog: Program, err: string) {
	lx := Lexer{src = src}
	p := Parser{lx = &lx}
	advance(&p)
	for p.tok.kind != .EOF {
		st, ok := parse_statement(&p)
		if !ok {
			return prog, p.err
		}
		if st != nil {
			append(&prog.stmts, st)
		}
	}
	// 词法错误可能出现在最后一个 token 之后（如未闭合的字符串），
	// 循环条件会先退出，因此在收尾时再检查一次。
	if p.err != "" {
		return prog, p.err
	}
	return prog, ""
}

// ---------------------------------------------------------------------------
// 求值
// ---------------------------------------------------------------------------

Env :: struct {
	vars:  map[string]Val,
	steps: int, // 表达式节点计数（防病态输入；--timeout 无循环可中断）
}

MAX_EVAL_STEPS :: 10_000_000

eval_expr :: proc(env: ^Env, e: ^Expr) -> (Val, string) {
	if e == nil {
		return val_undef(), ""
	}
	env.steps += 1
	if env.steps > MAX_EVAL_STEPS {
		return val_undef(), "expression too complex (step limit exceeded)"
	}

	switch e.kind {
	case .Lit:
		return e.val, ""
	case .Var:
		if v, ok := env.vars[e.name]; ok {
			return v, ""
		}
		return val_undef(), fmt.aprintf("undefined variable %q", e.name)
	case .Unary:
		v, err := eval_expr(env, e.kids[0])
		if err != "" {
			return val_undef(), err
		}
		switch e.op {
		case "!":
			return val_bool(!val_truthy(v)), ""
		case "-":
			#partial switch v.kind {
			case .Int:
				return val_int(-v.i), ""
			case .Float:
				return val_float(-v.f), ""
			}
			return val_undef(), "unary - requires a number"
		}
		return val_undef(), fmt.aprintf("unknown unary operator %q", e.op)
	case .Binary:
		return eval_binary(env, e)
	case .Ternary:
		cond, cerr := eval_expr(env, e.kids[0])
		if cerr != "" {
			return val_undef(), cerr
		}
		if val_truthy(cond) {
			return eval_expr(env, e.kids[1])
		}
		return eval_expr(env, e.kids[2])
	case .Call:
		return eval_call(env, e)
	}
	return val_undef(), "internal: unknown expression kind"
}

eval_binary :: proc(env: ^Env, e: ^Expr) -> (Val, string) {
	op := e.op
	// 短路
	if op == "&&" || op == "||" {
		l, lerr := eval_expr(env, e.kids[0])
		if lerr != "" {
			return val_undef(), lerr
		}
		lt := val_truthy(l)
		if op == "&&" && !lt {
			return val_bool(false), ""
		}
		if op == "||" && lt {
			return val_bool(true), ""
		}
		r, rerr := eval_expr(env, e.kids[1])
		if rerr != "" {
			return val_undef(), rerr
		}
		return val_bool(val_truthy(r)), ""
	}

	l, lerr := eval_expr(env, e.kids[0])
	if lerr != "" {
		return val_undef(), lerr
	}
	r, rerr := eval_expr(env, e.kids[1])
	if rerr != "" {
		return val_undef(), rerr
	}

	switch op {
	case "+":
		if l.kind == .Str && r.kind == .Str {
			return val_str(fmt.aprintf("%s%s", l.s, r.s)), ""
		}
		lf, l_int, lok := val_number(l)
		rf, r_int, rok := val_number(r)
		if !lok || !rok {
			return val_undef(), "invalid operation: + requires two numbers or two strings"
		}
		if l_int && r_int {
			return val_int(l.i + r.i), ""
		}
		return val_float(lf + rf), ""
	case "-", "*", "/", "%":
		lf, l_int, lok := val_number(l)
		rf, r_int, rok := val_number(r)
		if !lok || !rok {
			return val_undef(), fmt.aprintf("invalid operation: %s requires numbers", op)
		}
		if l_int && r_int {
			switch op {
			case "-":
				return val_int(l.i - r.i), ""
			case "*":
				return val_int(l.i * r.i), ""
			case "/":
				if r.i == 0 {
					return val_undef(), "division by zero"
				}
				return val_int(l.i / r.i), ""
			case "%":
				if r.i == 0 {
					return val_undef(), "division by zero"
				}
				return val_int(l.i % r.i), ""
			}
		}
		switch op {
		case "-":
			return val_float(lf - rf), ""
		case "*":
			return val_float(lf * rf), ""
		case "/":
			if rf == 0 {
				return val_undef(), "division by zero"
			}
			return val_float(lf / rf), ""
		case "%":
			return val_undef(), "% requires integers"
		}
	case "==", "!=":
		eq := values_equal(l, r)
		if op == "!=" {
			eq = !eq
		}
		return val_bool(eq), ""
	case "<", "<=", ">", ">=":
		cmp, cok := values_compare(l, r)
		if !cok {
			return val_undef(), fmt.aprintf("invalid operation: %s requires two numbers or two strings", op)
		}
		switch op {
		case "<":
			return val_bool(cmp < 0), ""
		case "<=":
			return val_bool(cmp <= 0), ""
		case ">":
			return val_bool(cmp > 0), ""
		case ">=":
			return val_bool(cmp >= 0), ""
		}
	}
	return val_undef(), fmt.aprintf("unknown binary operator %q", op)
}

values_equal :: proc(l, r: Val) -> bool {
	if l.kind == .Str && r.kind == .Str {
		return l.s == r.s
	}
	if l.kind == .Bool && r.kind == .Bool {
		return l.b == r.b
	}
	if l.kind == .Undef || r.kind == .Undef {
		return l.kind == r.kind
	}
	lf, _, lok := val_number(l)
	rf, _, rok := val_number(r)
	if lok && rok {
		return lf == rf
	}
	return false
}

// values_compare 返回 -1/0/1；不可比较时 ok=false。
values_compare :: proc(l, r: Val) -> (int, bool) {
	if l.kind == .Str && r.kind == .Str {
		if l.s == r.s {
			return 0, true
		}
		return -1 if l.s < r.s else 1, true
	}
	lf, _, lok := val_number(l)
	rf, _, rok := val_number(r)
	if lok && rok {
		if lf == rf {
			return 0, true
		}
		return -1 if lf < rf else 1, true
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// 函数调用（内建 + text.* + fmt.*）
// ---------------------------------------------------------------------------

eval_call :: proc(env: ^Env, e: ^Expr) -> (Val, string) {
	args := make([dynamic]Val, 0, len(e.kids), context.allocator)
	defer delete_dynamic_array(args)
	for k in e.kids {
		v, err := eval_expr(env, k)
		if err != "" {
			return val_undef(), err
		}
		append(&args, v)
	}
	return call_function(e.name, args[:])
}

arg_err :: proc(name: string, want: int, got: int) -> string {
	return fmt.aprintf("%s: expected %d argument(s), got %d", name, want, got)
}

// 拆 "mod.func" → (mod, func)；无点则 mod 为空。
split_qualified :: proc(name: string) -> (mod: string, fn: string) {
	if i := strings.last_index_byte(name, '.'); i >= 0 {
		return name[:i], name[i + 1:]
	}
	return "", name
}

call_function :: proc(name: string, a: []Val) -> (Val, string) {
	mod, fn := split_qualified(name)

	switch mod {
	case "":
		// 内建
		switch fn {
		case "import":
			// gx 的 -f 脚本要写 `text := import("text")`；odd 的模块函数
			// 本来就是全局可见的，这里只做**空绑定**让脚本原样跑通。
			if len(a) != 1 {
				return val_undef(), arg_err(name, 1, len(a))
			}
			return val_str(""), ""
		case "len":
			if len(a) != 1 {
				return val_undef(), arg_err(name, 1, len(a))
			}
			if a[0].kind == .Str {
				return val_int(i64(len(a[0].s))), ""
			}
			return val_undef(), "len() requires a string"
		case "string":
			if len(a) != 1 {
				return val_undef(), arg_err(name, 1, len(a))
			}
			return val_str(val_display(a[0])), ""
		case "int":
			if len(a) != 1 {
				return val_undef(), arg_err(name, 1, len(a))
			}
			#partial switch a[0].kind {
			case .Int:
				return a[0], ""
			case .Float:
				return val_int(i64(a[0].f)), ""
			case .Str:
				if v, ok := strconv.parse_i64(strings.trim_space(a[0].s)); ok {
					return val_int(v), ""
				}
				return val_undef(), fmt.aprintf(`int(): cannot convert %q`, a[0].s)
			case .Bool:
				return val_int(1 if a[0].b else 0), ""
			}
			return val_undef(), "int(): unsupported operand"
		}
		return val_undef(), fmt.aprintf("undefined function %q", name)

	case "text":
		return call_text(name, fn, a)

	case "fmt":
		if fn == "sprintf" {
			return call_sprintf(name, a)
		}
		return val_undef(), fmt.aprintf("undefined function %q", name)
	}
	return val_undef(), fmt.aprintf("unsupported module %q (odd script 只提供 text/fmt 与内置函数)", mod)
}

// call_text — text 模块（对应 Tengo text 里的字符串函数）。
call_text :: proc(name, fn: string, a: []Val) -> (Val, string) {
	// 先做参数类型检查助手
	if fn == "to_upper" || fn == "to_lower" || fn == "trim_space" || fn == "atoi" || fn == "itoa" {
		if len(a) != 1 {
			return val_undef(), arg_err(name, 1, len(a))
		}
		if fn == "itoa" {
			if a[0].kind != .Int {
				return val_undef(), "text.itoa() requires an integer"
			}
			return val_str(fmt.aprintf("%d", a[0].i)), ""
		}
		if a[0].kind != .Str {
			return val_undef(), fmt.aprintf("text.%s() requires a string", fn)
		}
		switch fn {
		case "to_upper":
			return val_str(strings.to_upper(a[0].s)), ""
		case "to_lower":
			return val_str(strings.to_lower(a[0].s)), ""
		case "trim_space":
			return val_str(strings.trim_space(a[0].s)), ""
		case "atoi":
			if v, ok := strconv.parse_i64(a[0].s); ok {
				return val_int(v), ""
			}
			return val_int(0), "" // Tengo 的 atoi 失败返回 0
		}
	}

	if fn == "trim" || fn == "trim_prefix" || fn == "trim_suffix" ||
	   fn == "contains" || fn == "has_prefix" || fn == "has_suffix" ||
	   fn == "index" || fn == "repeat" || fn == "replace" ||
	   fn == "re_match" || fn == "re_replace" {
		// 参数个数与类型逐个校验
		switch fn {
		case "trim", "trim_prefix", "trim_suffix", "contains", "has_prefix", "has_suffix", "index", "re_match":
			if len(a) != 2 {
				return val_undef(), arg_err(name, 2, len(a))
			}
			if a[0].kind != .Str || a[1].kind != .Str {
				return val_undef(), fmt.aprintf("text.%s() requires strings", fn)
			}
			switch fn {
			case "trim":
				return val_str(strings.trim(a[0].s, a[1].s)), ""
			case "trim_prefix":
				return val_str(strings.trim_prefix(a[0].s, a[1].s)), ""
			case "trim_suffix":
				return val_str(strings.trim_suffix(a[0].s, a[1].s)), ""
			case "contains":
				return val_bool(strings.contains(a[0].s, a[1].s)), ""
			case "has_prefix":
				return val_bool(strings.has_prefix(a[0].s, a[1].s)), ""
			case "has_suffix":
				return val_bool(strings.has_suffix(a[0].s, a[1].s)), ""
			case "index":
				return val_int(i64(strings.index(a[0].s, a[1].s))), ""
			case "re_match":
				return regex_bool(a[0].s, a[1].s)
			}
		case "repeat":
			if len(a) != 2 {
				return val_undef(), arg_err(name, 2, len(a))
			}
			if a[0].kind != .Str || a[1].kind != .Int {
				return val_undef(), "text.repeat() requires (string, int)"
			}
			if a[1].i < 0 {
				return val_undef(), "text.repeat(): negative count"
			}
			return val_str(strings.repeat(a[0].s, int(a[1].i))), ""
		case "replace":
			// Tengo 的 text.replace(s, old, new, n)：n<0 表示全部替换
			if len(a) != 4 {
				return val_undef(), arg_err(name, 4, len(a))
			}
			if a[0].kind != .Str || a[1].kind != .Str || a[2].kind != .Str || a[3].kind != .Int {
				return val_undef(), "text.replace() requires (string, string, string, int)"
			}
			merged, _ := strings.replace(a[0].s, a[1].s, a[2].s, int(a[3].i), context.allocator)
			return val_str(merged), ""
		case "re_replace":
			if len(a) != 3 {
				return val_undef(), arg_err(name, 3, len(a))
			}
			if a[0].kind != .Str || a[1].kind != .Str || a[2].kind != .Str {
				return val_undef(), "text.re_replace() requires strings"
			}
			return regex_replace(a[0].s, a[1].s, a[2].s)
		}
	}
	return val_undef(), fmt.aprintf("undefined function %q", name)
}

// regex_bool — 编译 pattern（大小写敏感）并检测 subject 是否命中。
regex_bool :: proc(pattern, subject: string) -> (Val, string) {
	re, ok := search.regex_compile(pattern, false)
	if !ok {
		return val_undef(), fmt.aprintf("text.re_match(): invalid pattern %q", pattern)
	}
	defer search.regex_destroy(re)
	return val_bool(search.regex_matches(re, transmute([]u8)subject)), ""
}

// regex_replace — 全量替换（$1 等模板语法与 replace 子命令一致）。
regex_replace :: proc(pattern, subject, repl: string) -> (Val, string) {
	re, ok := search.regex_compile(pattern, false)
	if !ok {
		return val_undef(), fmt.aprintf("text.re_replace(): invalid pattern %q", pattern)
	}
	defer search.regex_destroy(re)
	out, _ := search.regex_replace_all(re, transmute([]u8)subject, repl)
	result := string(out) // 所有权交给调用方的 arena
	return val_str(result), ""
}

// sprintf_is_flag — Go 的 flag 集合：'-'、'+'、' '、'0'、'#'。
sprintf_is_flag :: proc(c: u8) -> bool {
	return c == '-' || c == '+' || c == ' ' || c == '0' || c == '#'
}

sprintf_is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// sprintf_int — 把任意 Val 取成整型（'*' 宽度/精度用）。
sprintf_int :: proc(v: Val) -> i64 {
	switch v.kind {
	case .Int:
		return v.i
	case .Float:
		return i64(v.f)
	case .Bool:
		return 1 if v.b else 0
	case .Str, .Undef:
		return 0
	}
	return 0
}

// call_sprintf — fmt.sprintf 的顺序替换。
//
// 支持 Go 的完整格式串语法 %[flags][width][.precision]verb：
//   flags     '-'(左对齐) '+' ' '(空格) '0'(零填充) '#'(进制前缀)
//   width     十进制数字 或 '*'（吃一个整型实参）
//   precision '.' 后跟十进制数字 或 '*'（吃一个整型实参）
//   verb      s v d q t x X o b c f e E g G F %（未识别 → 原样输出）
// 解析出 spec 后直接交给 Odin 的 fmt 去格式化（%03d / %-5s / %5.2f 均等价）。
call_sprintf :: proc(name: string, a: []Val) -> (Val, string) {
	if len(a) < 1 {
		return val_undef(), arg_err(name, 1, 0)
	}
	if a[0].kind != .Str {
		return val_undef(), "fmt.sprintf(): first argument must be a format string"
	}
	fmt_str := a[0].s
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	argi := 1
	i := 0
	for i < len(fmt_str) {
		if fmt_str[i] != '%' {
			strings.write_byte(&b, fmt_str[i])
			i += 1
			continue
		}

		// ---- 解析 %[flags][width][.precision]verb ----
		p := i + 1
		flags_start := p
		for p < len(fmt_str) && sprintf_is_flag(fmt_str[p]) {
			p += 1
		}
		flags := fmt_str[flags_start:p]

		width_text: string
		if p < len(fmt_str) && fmt_str[p] == '*' {
			if argi >= len(a) {
				return val_undef(), "fmt.sprintf(): not enough arguments"
			}
			width_text = fmt.aprintf("%d", sprintf_int(a[argi]))
			argi += 1
			p += 1
		} else {
			ws := p
			for p < len(fmt_str) && sprintf_is_digit(fmt_str[p]) {
				p += 1
			}
			width_text = fmt_str[ws:p]
		}

		prec_text: string
		has_prec := false
		if p < len(fmt_str) && fmt_str[p] == '.' {
			has_prec = true
			p += 1
			if p < len(fmt_str) && fmt_str[p] == '*' {
				if argi >= len(a) {
					return val_undef(), "fmt.sprintf(): not enough arguments"
				}
				prec_text = fmt.aprintf("%d", sprintf_int(a[argi]))
				argi += 1
				p += 1
			} else {
				ps := p
				for p < len(fmt_str) && sprintf_is_digit(fmt_str[p]) {
					p += 1
				}
				prec_text = fmt_str[ps:p]
			}
		}

		// 悬挂的 '%'（到串尾也没等到动词）→ 剩余部分原样输出
		if p >= len(fmt_str) {
			strings.write_string(&b, fmt_str[i:])
			i = len(fmt_str)
			break
		}

		verb := fmt_str[p]
		i = p + 1

		if verb == '%' {
			strings.write_byte(&b, '%')
			continue
		}

		if argi >= len(a) {
			return val_undef(), "fmt.sprintf(): not enough arguments"
		}
		v := a[argi]
		argi += 1

		// ---- 组装等价的 Odin 格式串 ----
		sb: strings.Builder
		strings.builder_init(&sb, context.allocator)
		strings.write_byte(&sb, '%')
		strings.write_string(&sb, flags)
		strings.write_string(&sb, width_text)
		if has_prec {
			strings.write_byte(&sb, '.')
			strings.write_string(&sb, prec_text)
		}
		strings.write_byte(&sb, verb)
		spec := strings.to_string(sb)

		switch verb {
		case 's', 'v', 'q':
			strings.write_string(&b, fmt.aprintf(spec, val_display(v)))
		case 'd', 'x', 'X', 'o', 'b', 'c':
			#partial switch v.kind {
			case .Int:
				strings.write_string(&b, fmt.aprintf(spec, v.i))
			case .Float:
				strings.write_string(&b, fmt.aprintf(spec, i64(v.f)))
			case:
				strings.write_string(&b, val_display(v))
			}
		case 'f', 'e', 'E', 'g', 'G', 'F':
			#partial switch v.kind {
			case .Float:
				strings.write_string(&b, fmt.aprintf(spec, v.f))
			case .Int:
				strings.write_string(&b, fmt.aprintf(spec, f64(v.i)))
			case:
				strings.write_string(&b, val_display(v))
			}
		case 't':
			strings.write_string(&b, fmt.aprintf(spec, v.kind == .Bool && v.b))
		case:
			// 未识别的动词：原样回吐（Go 会输出 %!x(...)，此处宽松处理）
			strings.write_string(&b, spec)
		}
	}
	return val_str(strings.to_string(b)), ""
}

// ---------------------------------------------------------------------------
// 语句执行
// ---------------------------------------------------------------------------

// exec_program — 执行语句序列；__out 由脚本自行赋值（无赋值 → undefined）。
exec_program :: proc(env: ^Env, prog: Program) -> string {
	return exec_stmts(env, prog.stmts[:])
}

exec_stmts :: proc(env: ^Env, stmts: []^Stmt) -> string {
	for st in stmts {
		if st == nil {
			continue
		}
		#partial switch st.kind {
		case .Assign:
			v, err := eval_expr(env, st.expr)
			if err != "" {
				return err
			}
			env.vars[st.name] = v
		case .Expr_Stmt:
			if _, err := eval_expr(env, st.expr); err != "" {
				return err
			}
		case .If:
			c, err := eval_expr(env, st.cond)
			if err != "" {
				return err
			}
			if val_truthy(c) {
				if e := exec_stmts(env, st.then_body[:]); e != "" {
					return e
				}
			} else if e := exec_stmts(env, st.else_body[:]); e != "" {
				return e
			}
		}
	}
	return ""
}
