package search

// ============================================================================
// regex.odin — 正则表达式引擎（自研，Odin 无 core:regex）
//
// 复刻 gx/regex 对外行为（Go regexp 的常用子集）：
//   * 语法：字面量 `.` `^` `$` `\A` `\z` `\b` `\B`、字符类 `[...]`（含取反
//     与 `\d\w\s` 等简写）、分组 `(...)` / `(?:...)` / `(?i:...)` / 命名组、
//     alternation `|`、重复 `*` `+` `?` `{n}` `{n,}` `{n,m}`（含懒惰 `*?` 等）、
//     反向引用 `\1`..`\9`
//   * 标志：`(?i)` 大小写不敏感（ASCII 折叠）、`(?s)` 点匹配换行、
//     `(?m)`/`(?U)` 接受但按空操作（本就按行匹配）
//   * API：FindAllIndex 语义的 find_all（非重叠、空匹配后移一字节）、
//     ReplaceAll 的 $1/${name}/$$ 展开
//
// 实现：AST → 字节码（Split/Save/Jmp/Char/Class/...）→ 回溯 VM。
//   左优先序（与 Go regexp 默认语义一致，非 POSIX 最长匹配）。
//   纯字面量模式（无元字符）走子串搜索快路径，等价 gx -F 且默认生效。
//
// 与 Go 的已知差异（README 同步记录）：
//   * `(?i)` 为 ASCII 折叠，Go 为 Unicode 折叠
//   * 病态模式有步数上限（每起点 1<<20 步），超限返回 ok=false；
//     Go 的 RE2 为线性时间无此问题
//   * 反向引用 + "无进展循环裁剪"并存时有极端语义风险（见 vm_run 注释）
// ============================================================================

import "core:bytes"
import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"

// 每起点步数上限：超出即放弃（防止病态回溯拖死进程）。
MAX_STEPS_PER_START :: 1 << 20

// ---------------------------------------------------------------------------
// 字节码
// ---------------------------------------------------------------------------

Op :: enum {
	Char,
	Any,
	Class,
	Save,
	Split,
	Jmp,
	Match,
	Bol,
	Eol,
	Text_Start,
	Text_End,
	Word_B,
	Not_Word_B,
	Backref,
}

Inst :: struct {
	op:      Op,
	x:       int, // Jmp/Split 目标 / Class 索引 / Save 槽位 / Backref 组号
	y:       int, // Split 的第二目标
	ch:      u8, // Char 的字节
	ci:      bool, // Char 比较时折叠大小写
	lazy:    bool, // Split 为懒惰型（先尝试退出分支）
	dot_all: bool, // Any 是否吃 '\n'（(?s)）
}

// 字符类：区间表 + 取反。区间表在编译期完成大小写扩展（ci 模式）。
Class :: struct {
	ranges:  [][2]u8,
	negated: bool,
}

class_contains :: proc "contextless" (c: Class, b: u8) -> bool {
	found := false
	for r in c.ranges {
		if b >= r[0] && b <= r[1] {
			found = true
			break
		}
	}
	return found != c.negated
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

Node_Kind :: enum {
	Empty,
	Char,
	Any_Char,
	Class,
	Bol,
	Eol,
	Text_Start,
	Text_End,
	Word_B,
	Not_Word_B,
	Concat,
	Alternate,
	Repeat,
	Group,
}

Node :: struct {
	kind:      Node_Kind,
	ch:        u8,
	ci:        bool, // Char 生效中的 (?i)
	dot_all:   bool, // Any_Char 生效中的 (?s)
	class:     Class,
	sub:       ^Node,
	lo:        int, // Repeat 下限；hi = -1 表示无上限
	hi:        int,
	greedy:    bool,
	kids:      [dynamic]^Node,
	group_idx: int, // Group 的捕获组号（0 = 非捕获）；反向引用时携带组号
	backref:   bool, // true → 这是 \N 反向引用而非分组
}

// ---------------------------------------------------------------------------
// 编译产物
// ---------------------------------------------------------------------------

Regex :: struct {
	prog:         []Inst,
	classes:      []Class,
	ngroups:      int, // 捕获组数量（不含整匹配）
	group_names:  []string, // 长度 ngroups+1，下标 0 为整匹配（空名）
	literal:      []u8, // 非 nil → 纯字面量快路径（ci 已体现在内容）
	ci_literal:   bool, // 字面量比较是否折叠大小写
	prefix:       []u8, // 非 nil → **前导**字面字节，用于 VM 路径跳过无效起点
	allocator:    runtime.Allocator,
}

// 一次匹配（含捕获组平表 [2*(ngroups+1)]int，-1 表示未参与）。
Match :: struct {
	start:  int,
	end:    int,
	groups: []int,
}

// ---------------------------------------------------------------------------
// 解析器
// ---------------------------------------------------------------------------

Parser :: struct {
	pat:         string,
	pos:         int,
	ci:          bool,
	dot_all:     bool,
	ngroups:     int,
	names:       [dynamic]string, // 组名（下标 = 组号 - 1；未命名存 ""）
	has_backref: bool,
	allocator:   runtime.Allocator,
}

peek :: proc(p: ^Parser) -> (u8, bool) {
	if p.pos >= len(p.pat) {
		return 0, false
	}
	return p.pat[p.pos], true
}

peek_at :: proc(p: ^Parser, off: int) -> (u8, bool) {
	if p.pos + off >= len(p.pat) {
		return 0, false
	}
	return p.pat[p.pos + off], true
}

next :: proc(p: ^Parser) -> (u8, bool) {
	if p.pos >= len(p.pat) {
		return 0, false
	}
	c := p.pat[p.pos]
	p.pos += 1
	return c, true
}

// alternate := concat ('|' concat)*
parse_alternate :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	first, first_ok := parse_concat(p)
	if !first_ok {
		return nil, false
	}
	alts: [dynamic]^Node
	append(&alts, first)
	for {
		c, has := peek(p)
		if !has || c != '|' {
			break
		}
		p.pos += 1
		next_alt, next_ok := parse_concat(p)
		if !next_ok {
			delete_nodes(alts[:], p.allocator)
			return nil, false
		}
		append(&alts, next_alt)
	}
	if len(alts) == 1 {
		only := alts[0]
		delete(alts)
		return only, true
	}
	node := new(Node, p.allocator)
	node.kind = .Alternate
	node.kids = alts
	return node, true
}

// concat := repeat*
parse_concat :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	kids: [dynamic]^Node
	for {
		c, has := peek(p)
		if !has || c == '|' || c == ')' {
			break
		}
		piece, piece_ok := parse_repeat(p)
		if !piece_ok {
			delete_nodes(kids[:], p.allocator)
			return nil, false
		}
		append(&kids, piece)
	}
	if len(kids) == 0 {
		delete(kids)
		node := new(Node, p.allocator)
		node.kind = .Empty
		return node, true
	}
	if len(kids) == 1 {
		only := kids[0]
		delete(kids)
		return only, true
	}
	node := new(Node, p.allocator)
	node.kind = .Concat
	node.kids = kids
	return node, true
}

// repeat := atom (('*' | '+' | '?' | '{n,m}') '?'?)*
// 注意：Odin 的 break 在 switch 内只跳出 switch——退出外层循环必须用
// 标签 break（曾因裸 break 写成死循环：peek 反复返回同一字符）。
parse_repeat :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	atom, atom_ok := parse_atom(p)
	if !atom_ok {
		return nil, false
	}
repeat_loop: for {
		c, has := peek(p)
		if !has {
			break
		}
		lo, hi := 0, 0
		switch c {
		case '*':
			p.pos += 1
			lo, hi = 0, -1
		case '+':
			p.pos += 1
			lo, hi = 1, -1
		case '?':
			p.pos += 1
			lo, hi = 0, 1
		case '{':
			parsed_lo, parsed_hi, brace_ok, is_repeat := try_parse_brace(p)
			if !is_repeat {
				break repeat_loop // `{` 不是合法重复 → 停止（字面量已由 atom 消费）
			}
			if !brace_ok {
				free_node(atom, p.allocator)
				return nil, false
			}
			lo, hi = parsed_lo, parsed_hi
		case:
			break repeat_loop
		}
		greedy := true
		if nc, nc_has := peek(p); nc_has && nc == '?' {
			p.pos += 1
			greedy = false
		}
		node := new(Node, p.allocator)
		node.kind = .Repeat
		node.sub = atom
		node.lo = lo
		node.hi = hi
		node.greedy = greedy
		atom = node
	}
	return atom, true
}

// 尝试把 `{...}` 解析为重复。is_repeat=false 表示这不是重复语法（字面量）。
try_parse_brace :: proc(p: ^Parser) -> (lo: int, hi: int, ok: bool, is_repeat: bool) {
	save := p.pos
	p.pos += 1 // 吃掉 '{'
	lo_buf: [32]u8
	hi_buf: [32]u8
	lo_n, hi_n := 0, 0
	seen_comma := false
	closed := false
	for p.pos < len(p.pat) {
		c := p.pat[p.pos]
		p.pos += 1
		if c == '}' {
			closed = true
			break
		}
		if c == ',' {
			if seen_comma {
				p.pos = save
				return 0, 0, false, false
			}
			seen_comma = true
			continue
		}
		if c < '0' || c > '9' {
			p.pos = save
			return 0, 0, false, false
		}
		if seen_comma {
			if hi_n >= len(hi_buf) {
				p.pos = save
				return 0, 0, false, false
			}
			hi_buf[hi_n] = c
			hi_n += 1
		} else {
			if lo_n >= len(lo_buf) {
				p.pos = save
				return 0, 0, false, false
			}
			lo_buf[lo_n] = c
			lo_n += 1
		}
	}
	if !closed || (lo_n == 0 && hi_n == 0) {
		p.pos = save
		return 0, 0, false, false
	}
	lo_val := 0
	if lo_n > 0 {
		v, v_ok := strconv.parse_int(string(lo_buf[:lo_n]))
		if !v_ok {
			p.pos = save
			return 0, 0, false, false
		}
		lo_val = v
	}
	hi_val := -1
	if hi_n > 0 {
		v, v_ok := strconv.parse_int(string(hi_buf[:hi_n]))
		if !v_ok {
			return 0, 0, false, true // 明确是重复但非法
		}
		hi_val = v
	} else if !seen_comma {
		hi_val = lo_val
	}
	if hi_val != -1 && hi_val < lo_val {
		return 0, 0, false, true
	}
	return lo_val, hi_val, true, true
}

// atom := '(' ... ')' | '[' class ']' | '.' | '^' | '$' | '\' escape | 字面量
parse_atom :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	c, has := peek(p)
	if !has {
		return nil, false
	}
	switch c {
	case '(':
		return parse_group(p)
	case '[':
		return parse_class(p)
	case '.':
		p.pos += 1
		node := new(Node, p.allocator)
		node.kind = .Any_Char
		node.dot_all = p.dot_all
		return node, true
	case '^':
		p.pos += 1
		node := new(Node, p.allocator)
		node.kind = .Bol
		return node, true
	case '$':
		p.pos += 1
		node := new(Node, p.allocator)
		node.kind = .Eol
		return node, true
	case '\\':
		return parse_escape(p)
	case '*', '+', '?':
		return nil, false // 重复符缺少操作数
	case ')':
		return nil, false
	case:
		p.pos += 1
		node := new(Node, p.allocator)
		node.kind = .Char
		node.ch = c
		node.ci = p.ci
		return node, true
	}
}

// '(' ('?:' | '?i:' | '(?flags)' | '(?P<name>' | 普通捕获) alternate ')'
parse_group :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	p.pos += 1 // '('
	group_idx := 0
	capturing := true
	group_name := "" // 命名组的名字（未命名为空）

	if nc, nc_has := peek(p); nc_has && nc == '?' {
		p.pos += 1 // 吃掉 '?'
		fc, fc_has := next(p) // '?' 后的第一个字符（标志或 ':' 或 'P'/'<'）
		if !fc_has {
			return nil, false
		}
		switch fc {
		case ':':
			capturing = false
		case 'P', '<':
			// 命名组 (?P<name>...) / (?<name>...)
			if fc == 'P' {
				if _, ok2 := next(p); !ok2 { // 吃掉 'P'
					return nil, false
				}
			}
			name_start := p.pos
			for {
				ch, ch_has := next(p)
				if !ch_has {
					return nil, false
				}
				if ch == '>' {
					break
				}
			}
			group_name = p.pat[name_start:p.pos - 1] // 借用 pattern（编译期克隆）
			capturing = true // 命名组照常捕获
		case:
			// 标志组：读取 i/s/m/U 序列，遇 ')' 为全局标志，遇 ':' 为局部标志组
			set_ci, set_dot_all := false, false
			valid := true
			for {
				switch fc {
				case 'i':
					set_ci = true
				case 's':
					set_dot_all = true
				case 'm', 'U':
					// 接受但空操作（见文件头说明）
				case '-':
					valid = false // (?-i) 负向标志不支持
				case:
					valid = false
				}
				if !valid {
					return nil, false
				}
				nxt, nxt_has := peek(p)
				if !nxt_has {
					return nil, false
				}
				if nxt == ')' {
					p.pos += 1
					if set_ci {
						p.ci = true
					}
					if set_dot_all {
						p.dot_all = true
					}
					node := new(Node, p.allocator)
					node.kind = .Empty
					return node, true
				}
				if nxt == ':' {
					p.pos += 1
					saved_ci, saved_dot := p.ci, p.dot_all
					if set_ci {
						p.ci = true
					}
					if set_dot_all {
						p.dot_all = true
					}
					inner, inner_ok := parse_alternate(p)
					p.ci, p.dot_all = saved_ci, saved_dot
					if !inner_ok {
						return nil, false
					}
					if !expect(p, ')') {
						free_node(inner, p.allocator)
						return nil, false
					}
					return inner, true
				}
				fc, fc_has = next(p)
				if !fc_has {
					return nil, false
				}
			}
		}
	}

	if capturing {
		p.ngroups += 1
		group_idx = p.ngroups
		append(&p.names, group_name) // 组名与组号同序登记（嵌套也一致）
	}
	inner, inner_ok := parse_alternate(p)
	if !inner_ok {
		return nil, false
	}
	if !expect(p, ')') {
		free_node(inner, p.allocator)
		return nil, false
	}
	if !capturing {
		return inner, true
	}
	node := new(Node, p.allocator)
	node.kind = .Group
	node.sub = inner
	node.group_idx = group_idx
	return node, true
}

expect :: proc(p: ^Parser, c: u8) -> bool {
	nc, has := next(p)
	return has && nc == c
}

// '[' '^'? items ']'
parse_class :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	p.pos += 1 // '['
	negated := false
	if nc, has := peek(p); has && nc == '^' {
		negated = true
		p.pos += 1
	}
	ranges: [dynamic][2]u8
	first := true
	for {
		c, has := peek(p)
		if !has {
			delete(ranges)
			return nil, false // 未闭合
		}
		if c == ']' && !first {
			p.pos += 1
			break
		}
		first = false

		if c == '\\' {
			p.pos += 1
			ec, ec_has := next(p)
			if !ec_has {
				delete(ranges)
				return nil, false
			}
			if cls, is_cls := shorthand_class(ec); is_cls {
				for r in cls.ranges {
					append(&ranges, r)
				}
				delete(cls.ranges)
				continue
			}
			ch := unescape_char(ec)
			if try_class_range(p, ch, &ranges) {
				continue
			}
			append(&ranges, [2]u8{ch, ch})
			continue
		}

		if c == '-' && len(ranges) > 0 {
			// 范围分隔符（前一个区间已入表）
			if nc, nc_has := peek_at(p, 1); nc_has && nc != ']' {
				prev := ranges[len(ranges) - 1][1]
				p.pos += 1 // 吃掉 '-'
				hc, hc_has := next(p)
				if !hc_has {
					delete(ranges)
					return nil, false
				}
				hi := hc
				if hc == '\\' {
					ecc, ecc_has := next(p)
					if !ecc_has {
						delete(ranges)
						return nil, false
					}
					if _, is_cls := shorthand_class(ecc); is_cls {
						delete(ranges)
						return nil, false // [a-\d] 非法
					}
					hi = unescape_char(ecc)
				}
				if prev > hi {
					delete(ranges)
					return nil, false
				}
				ranges[len(ranges) - 1] = [2]u8{prev, hi}
				continue
			}
			p.pos += 1
			append(&ranges, [2]u8{'-', '-'}) // 尾部 '-' 按字面量
			continue
		}

		p.pos += 1
		if try_class_range(p, c, &ranges) {
			continue
		}
		append(&ranges, [2]u8{c, c})
	}
	node := new(Node, p.allocator)
	node.kind = .Class
	node.class = Class{ranges = ranges[:], negated = negated}
	if p.ci && !negated {
		// ci 模式：区间向两种大小写形态扩展（原表释放，所有权移交扩展表）
		expanded := expand_class_ci(node.class.ranges, p.allocator)
		delete_dynamic_array(ranges)
		node.class.ranges = expanded
	}
	return node, true
}

// 已消费字符 ch 后，若下一个是 '-' 且再下一个不是 ']'，则构成范围 ch-hi。
try_class_range :: proc(p: ^Parser, ch: u8, ranges: ^[dynamic][2]u8) -> (consumed: bool) {
	if nc, nc_has := peek(p); !nc_has || nc != '-' {
		return false
	}
	nc2, nc2_has := peek_at(p, 1)
	if !nc2_has || nc2 == ']' {
		return false
	}
	p.pos += 1 // 吃掉 '-'
	hc, hc_has := next(p)
	if !hc_has {
		return true // 异常输入，交由上层报错
	}
	hi := hc
	if hc == '\\' {
		ecc, ecc_has := next(p)
		if !ecc_has {
			return true
		}
		if _, is_cls := shorthand_class(ecc); is_cls {
			return true // [\d-x] 类非法组合，简化处理
		}
		hi = unescape_char(ecc)
	}
	if ch > hi {
		return true // 非法范围，上层 delete 后报错
	}
	append(ranges, [2]u8{ch, hi})
	return true
}

// 简写类 → 区间表（新分配，调用方持有所有权；negated 时 ranges 为被取反的内容）。
shorthand_class :: proc(c: u8) -> (cls: Class, ok: bool) {
	ranges: [dynamic][2]u8
	switch c {
	case 'd':
		append(&ranges, [2]u8{'0', '9'})
	case 'D':
		append(&ranges, [2]u8{'0', '9'})
		clone := slice.clone(ranges[:], context.allocator)
		delete_dynamic_array(ranges)
		return Class{ranges = clone, negated = true}, true
	case 'w':
		append(&ranges, [2]u8{'0', '9'}, [2]u8{'A', 'Z'}, [2]u8{'_', '_'}, [2]u8{'a', 'z'})
	case 'W':
		append(&ranges, [2]u8{'0', '9'}, [2]u8{'A', 'Z'}, [2]u8{'_', '_'}, [2]u8{'a', 'z'})
		clone := slice.clone(ranges[:], context.allocator)
		delete_dynamic_array(ranges)
		return Class{ranges = clone, negated = true}, true
	case 's':
		append(&ranges, [2]u8{'\t', '\r'}, [2]u8{' ', ' '})
	case 'S':
		append(&ranges, [2]u8{'\t', '\r'}, [2]u8{' ', ' '})
		clone := slice.clone(ranges[:], context.allocator)
		delete_dynamic_array(ranges)
		return Class{ranges = clone, negated = true}, true
	case:
		return {}, false
	}
	clone := slice.clone(ranges[:], context.allocator)
	delete_dynamic_array(ranges)
	return Class{ranges = clone, negated = false}, true
}

// 控制字符转义。
unescape_char :: proc(c: u8) -> u8 {
	switch c {
	case 'n':
		return '\n'
	case 't':
		return '\t'
	case 'r':
		return '\r'
	case 'f':
		return '\f'
	case 'v':
		return '\v'
	case 'a':
		return '\a'
	case '0':
		return 0
	}
	return c
}

// '\' 转义序列（字符类之外）。
parse_escape :: proc(p: ^Parser) -> (n: ^Node, ok: bool) {
	p.pos += 1 // '\'
	c, has := next(p)
	if !has {
		return nil, false
	}
	switch c {
	case 'd', 'D', 'w', 'W', 's', 'S':
		cls, _ := shorthand_class(c)
		node := new(Node, p.allocator)
		node.kind = .Class
		if p.ci && !cls.negated {
			expanded := expand_class_ci(cls.ranges, p.allocator)
			delete(cls.ranges)
			cls.ranges = expanded
		}
		node.class = cls
		return node, true
	case 'b':
		node := new(Node, p.allocator)
		node.kind = .Word_B
		return node, true
	case 'B':
		node := new(Node, p.allocator)
		node.kind = .Not_Word_B
		return node, true
	case 'A':
		node := new(Node, p.allocator)
		node.kind = .Text_Start
		return node, true
	case 'z':
		node := new(Node, p.allocator)
		node.kind = .Text_End
		return node, true
	case 'x':
		hc1, hc1_ok := peek_at(p, 0)
		hc2, hc2_ok := peek_at(p, 1)
		h1, h1_ok := hex_val(hc1)
		h2, h2_ok := hex_val(hc2)
		if !hc1_ok || !hc2_ok || !h1_ok || !h2_ok {
			return nil, false
		}
		p.pos += 2
		node := new(Node, p.allocator)
		node.kind = .Char
		node.ch = u8(h1 << 4 | h2)
		node.ci = p.ci
		return node, true
	case '1', '2', '3', '4', '5', '6', '7', '8', '9':
		g := int(c - '0')
		if g > p.ngroups {
			return nil, false // 反向引用不存在的组
		}
		p.has_backref = true
		node := new(Node, p.allocator)
		node.kind = .Group
		node.group_idx = g
		node.backref = true
		return node, true
	case:
		node := new(Node, p.allocator)
		node.kind = .Char
		node.ch = unescape_char(c)
		node.ci = p.ci
		return node, true
	}
}

hex_val :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9':
		return int(c - '0'), true
	case 'a' ..= 'f':
		return int(c - 'a' + 10), true
	case 'A' ..= 'F':
		return int(c - 'A' + 10), true
	}
	return 0, false
}

// ci 区间扩展：把每个区间与 A-Z / a-z 的交集映射到另一形态。
// 返回新表；调用方负责释放原表。
expand_class_ci :: proc(ranges: [][2]u8, allocator: runtime.Allocator) -> [][2]u8 {
	out := make([dynamic][2]u8, 0, len(ranges) * 2, allocator)
	for r in ranges {
		append(&out, r)
		lo := max(r[0], u8('A'))
		hi := min(r[1], u8('Z'))
		if lo <= hi {
			append(&out, [2]u8{lo + 32, hi + 32})
		}
		lo = max(r[0], u8('a'))
		hi = min(r[1], u8('z'))
		if lo <= hi {
			append(&out, [2]u8{lo - 32, hi - 32})
		}
	}
	// 返回定长克隆：调用方以 delete(slice) 释放，与动态数组底座的
	// cap/len 不匹配问题（Odin delete 按 len 计算大小）解耦。
	result := slice.clone(out[:], allocator)
	delete_dynamic_array(out)
	return result
}

// ---------------------------------------------------------------------------
// 编译：AST → 字节码
// ---------------------------------------------------------------------------

Compiler :: struct {
	prog:      [dynamic]Inst,
	classes:   [dynamic]Class,
	allocator: runtime.Allocator,
}

emit :: proc(c: ^Compiler, inst: Inst) -> int {
	append(&c.prog, inst)
	return len(c.prog) - 1
}

compile_node :: proc(c: ^Compiler, n: ^Node) {
	switch n.kind {
	case .Empty:
	case .Char:
		ch := n.ch
		if n.ci {
			ch = lower_ascii(ch)
		}
		emit(c, Inst{op = .Char, ch = ch, ci = n.ci})
	case .Any_Char:
		emit(c, Inst{op = .Any, dot_all = n.dot_all})
	case .Class:
		// 深拷贝区间：Node 会被释放，classes 必须独立持有
		ranges_copy := make([][2]u8, len(n.class.ranges), c.allocator)
		copy(ranges_copy, n.class.ranges)
		idx := len(c.classes)
		append(&c.classes, Class{ranges = ranges_copy, negated = n.class.negated})
		emit(c, Inst{op = .Class, x = idx})
	case .Bol:
		emit(c, Inst{op = .Bol})
	case .Eol:
		emit(c, Inst{op = .Eol})
	case .Text_Start:
		emit(c, Inst{op = .Text_Start})
	case .Text_End:
		emit(c, Inst{op = .Text_End})
	case .Word_B:
		emit(c, Inst{op = .Word_B})
	case .Not_Word_B:
		emit(c, Inst{op = .Not_Word_B})
	case .Group:
		if n.backref {
			emit(c, Inst{op = .Backref, x = n.group_idx})
			break
		}
		g := n.group_idx
		emit(c, Inst{op = .Save, x = 2 * g})
		compile_node(c, n.sub)
		emit(c, Inst{op = .Save, x = 2 * g + 1})
	case .Concat:
		for kid in n.kids {
			compile_node(c, kid)
		}
	case .Alternate:
		// L1: Split L2, L3 ; L2: <a> ; Jmp L4 ; L3: <b> ; L4:
		jmp_ends: [dynamic]int
		for i in 0..<len(n.kids) {
			if i < len(n.kids) - 1 {
				split_pc := emit(c, Inst{op = .Split})
				c.prog[split_pc].x = split_pc + 1
				compile_node(c, n.kids[i])
				jmp_pc := emit(c, Inst{op = .Jmp})
				append(&jmp_ends, jmp_pc)
				c.prog[split_pc].y = len(c.prog)
				continue
			}
			compile_node(c, n.kids[i])
		}
		end := len(c.prog)
		for j in jmp_ends {
			c.prog[j].x = end
		}
		delete(jmp_ends)
	case .Repeat:
		compile_repeat(c, n)
	}
}

// 重复展开。{n,m} 用朴素展开（n 份拷贝 + 可选部分），规模受模式长度约束。
compile_repeat :: proc(c: ^Compiler, n: ^Node) {
	lo, hi := n.lo, n.hi
	if hi != -1 && hi < lo {
		return // 解析期已拦截，防御性返回
	}
	for _ in 0..<lo {
		compile_node(c, n.sub)
	}
	if hi == -1 {
		// 星号：L1: Split 循环体, 退出 ; 循环体: <sub> ; Jmp L1 ; 退出:
		l1 := emit(c, Inst{op = .Split, lazy = !n.greedy})
		body_start := l1 + 1
		compile_node(c, n.sub)
		jmp_pc := emit(c, Inst{op = .Jmp})
		c.prog[jmp_pc].x = l1
		exit_pc := len(c.prog)
		if n.greedy {
			c.prog[l1].x = body_start
			c.prog[l1].y = exit_pc
		} else {
			c.prog[l1].x = exit_pc
			c.prog[l1].y = body_start
		}
		return
	}
	// 可选部分：hi - lo 个 '?'
	opt := hi - lo
	if opt > 0 {
		split_pcs: [dynamic]int
		for _ in 0..<opt {
			sp := emit(c, Inst{op = .Split, lazy = !n.greedy})
			append(&split_pcs, sp)
			compile_node(c, n.sub)
		}
		end := len(c.prog)
		for sp in split_pcs {
			body := sp + 1
			if n.greedy {
				c.prog[sp].x = body
				c.prog[sp].y = end
			} else {
				c.prog[sp].x = end
				c.prog[sp].y = body
			}
		}
		delete(split_pcs)
	}
}

// ---------------------------------------------------------------------------
// 对外 API
// ---------------------------------------------------------------------------

// 编译正则。ignore_case 等价于在模式头部插入 (?i)。
regex_compile :: proc(pattern: string, ignore_case: bool) -> (re: ^Regex, ok: bool) {
	p := Parser{
		pat       = pattern,
		ci        = ignore_case,
		allocator = context.allocator,
	}
	root, root_ok := parse_alternate(&p)
	if !root_ok || p.pos != len(p.pat) {
		if root_ok {
			free_node(root, context.allocator)
		}
		delete_dynamic_array(p.names) // 名字是 pattern 的视图，只释放数组
		return nil, false
	}

	re = new(Regex, context.allocator)
	re.allocator = context.allocator
	re.ngroups = p.ngroups

	// 组名表：下标 0 是整匹配（空名），1..n 对应捕获组；名字克隆进
	// re.allocator，使 pattern 串（可能是临时缓冲）先释放也安全。
	names := make([]string, p.ngroups + 1, context.allocator)
	for name, i in p.names {
		if i + 1 > p.ngroups {
			break
		}
		if name != "" {
			if cl, cerr := strings.clone(name, context.allocator); cerr == nil {
				names[i + 1] = cl
			}
		}
	}
	re.group_names = names
	delete_dynamic_array(p.names)

	c := Compiler{allocator = context.allocator}
	emit(&c, Inst{op = .Save, x = 0}) // caps[0] = 整匹配起点
	compile_node(&c, root)
	emit(&c, Inst{op = .Save, x = 1}) // caps[1] = 整匹配终点
	emit(&c, Inst{op = .Match})

	// 定长克隆接管：动态数组的 cap 可能大于 len，直接切片交给
	// delete(slice) 会因大小不匹配被追踪分配器判为泄漏。
	re.prog = slice.clone(c.prog[:], context.allocator)
	re.classes = slice.clone(c.classes[:], context.allocator)
	delete_dynamic_array(c.prog)
	delete_dynamic_array(c.classes)
	re.literal = extract_literal(root, p.ci, context.allocator)
	re.ci_literal = p.ci
	// 非纯字面量模式也可能带前导字面串（`foo\d+`）：留着做起点跳转。
	// 纯字面量模式已有更快的整串搜索路径，不必再存。
	if re.literal == nil {
		re.prefix = extract_prefix_literal(root, p.ci, context.allocator)
	}

	free_node(root, context.allocator)
	return re, true
}

regex_destroy :: proc(re: ^Regex) {
	if re == nil {
		return
	}
	delete(re.prog, re.allocator)
	for cls in re.classes {
		delete(cls.ranges, re.allocator)
	}
	delete(re.classes, re.allocator)
	for name, i in re.group_names {
		if i > 0 && name != "" {
			delete(name, re.allocator)
		}
	}
	delete(re.group_names, re.allocator)
	if re.literal != nil {
		delete(re.literal, re.allocator)
	}
	if re.prefix != nil {
		delete(re.prefix, re.allocator)
	}
	free(re, re.allocator)
}

// 若 AST 是纯字面量序列，返回其字节（ci 时全部小文化）；否则 nil。
extract_literal :: proc(n: ^Node, ci: bool, allocator: runtime.Allocator) -> []u8 {
	#partial switch n.kind {
	case .Char:
		buf := make([]u8, 1, allocator)
		buf[0] = n.ch
		if ci {
			buf[0] = lower_ascii(buf[0])
		}
		return buf
	case .Concat:
		buf: [dynamic]u8
		for kid in n.kids {
			piece := extract_literal(kid, ci, allocator)
			if piece == nil {
				delete_dynamic_array(buf)
				return nil
			}
			append(&buf, ..piece)
			delete(piece, allocator)
		}
		if len(buf) == 0 {
			delete_dynamic_array(buf)
			return nil
		}
		result := slice.clone(buf[:], allocator)
		delete_dynamic_array(buf)
		return result
	case:
		return nil
	}
}

// 提取**前导**字面字节（尽可能多），用于 VM 路径跳过不可能的起点。
//
// 与 extract_literal 的区别：后者要求整棵树都是字面量（否则 nil），
// 而这里只要最前面连续若干个 Char 节点即可 —— `foo\d+` 整串不是字面量，
// 但任何匹配必然以 "foo" 开头。
//
// 保守边界（拿不到就返回 nil，不做任何跳过）：
//   * 遇到非 Char 节点立即停止（Group / Repeat{0,n} / Class / 断言 都算）
//   * 只在顶层 Concat 里向前扫，不进组、不进 alternation
// 这两条保证"任何匹配必以该字节串开头"成立，跳过非候选位置才安全。
extract_prefix_literal :: proc(n: ^Node, ci: bool, allocator: runtime.Allocator) -> []u8 {
	buf: [dynamic]u8
	#partial switch n.kind {
	case .Char:
		append(&buf, lower_ascii(n.ch) if ci else n.ch)
	case .Concat:
		for kid in n.kids {
			if kid == nil || kid.kind != .Char {
				break
			}
			append(&buf, lower_ascii(kid.ch) if ci else kid.ch)
		}
	case:
		// 其余一律放弃
	}
	if len(buf) == 0 {
		delete_dynamic_array(buf)
		return nil
	}
	result := slice.clone(buf[:], allocator)
	delete_dynamic_array(buf)
	return result
}

// 前导字节串是否出现在 data[pos:] 的开头（ci 时两边都已折小写）。
prefix_at :: proc(re: ^Regex, data: []u8, pos: int) -> bool {
	p := re.prefix
	if pos < 0 || pos + len(p) > len(data) {
		return false
	}
	if !re.ci_literal {
		return bytes.equal(data[pos:pos + len(p)], p)
	}
	for k in 0..<len(p) {
		if lower_ascii(data[pos + k]) != p[k] {
			return false
		}
	}
	return true
}

// 首字节大小写折叠时要用 memchr 找**两种**形态再取较近的那个；
// 只找小写字形态会漏掉 "FOO"（ci 前缀索引 bug 的出处）。
prefix_find_first_byte :: proc "contextless" (re: ^Regex, rest: []u8) -> int {
	b0 := re.prefix[0]
	j := bytes.index_byte(rest, b0)
	if !re.ci_literal {
		return j
	}
	upper := upper_ascii(b0)
	if upper == b0 {
		return j
	}
	j2 := bytes.index_byte(rest, upper)
	if j2 < 0 {
		return j
	}
	if j < 0 || j2 < j {
		return j2
	}
	return j
}

// 返回 >= from 的第一个候选起点；没有则返回 -1。
// 先按首字节用 bytes.index_byte 整段跳（memchr 级），再校验整串。
prefix_next_candidate :: proc(re: ^Regex, data: []u8, from: int) -> int {
	p := re.prefix
	if len(p) == 0 || from < 0 {
		return -1
	}
	limit := len(data) - len(p)
	if from > limit {
		return -1
	}
	i := from
	for i <= limit {
		j := prefix_find_first_byte(re, data[i:])
		if j < 0 {
			return -1
		}
		i += j
		if i > limit {
			return -1
		}
		if prefix_at(re, data, i) {
			return i
		}
		i += 1
	}
	return -1
}

// 查找全部非重叠匹配（FindAllIndex 语义：空匹配也记录，之后前移一字节）。
// 返回动态数组（含每匹配的 groups 平表），由 regex_free_matches 释放。
regex_find_all :: proc(re: ^Regex, data: []u8) -> (matches: [dynamic]Match, ok: bool) {
	matches, ok = find_all_impl(re, data, false)
	return
}

// 查找第一个匹配（带捕获组）。未命中返回 ok=false。
// 返回的 m.groups 所有权归调用方，需 delete(m.groups, re.allocator)。
regex_find_first :: proc(re: ^Regex, data: []u8) -> (m: Match, ok: bool) {
	ms, found := find_all_impl(re, data, true)
	if !found || len(ms) == 0 {
		regex_free_matches(re, &ms)
		return {}, false
	}
	m = ms[0]
	ms[0].groups = nil // 所有权转移，避免 regex_free_matches 双重释放
	regex_free_matches(re, &ms)
	return m, true
}

// 是否包含至少一个匹配（MatchString 语义：全文任意位置，非仅锚定起点）。
regex_matches :: proc(re: ^Regex, data: []u8) -> bool {
	if re.literal != nil {
		return literal_index(re, data, 0) >= 0
	}
	caps := make([]int, 2 * (re.ngroups + 1), re.allocator)
	defer delete(caps, re.allocator)
	scratch: VM_Scratch
	defer vm_scratch_destroy(re, &scratch)
	vm_scratch_ensure(re, &scratch)
	pos := 0
	for {
		if re.prefix != nil && pos > 0 {
			// 与 find_all_impl 同源的跳过逻辑：只试前导串命中的起点
			cand := prefix_next_candidate(re, data, pos)
			if cand < 0 {
				return false
			}
			pos = cand
		}
		if pos > len(data) {
			return false
		}
		if vm_run_scratch(re, &scratch, data, pos, caps) {
			return true
		}
		pos += 1
	}
}

find_all_impl :: proc(re: ^Regex, data: []u8, first_only: bool) -> (out: [dynamic]Match, ok: bool) {
	defer if !ok {
		regex_free_matches(re, &out)
	}

	ncaps := re.ngroups
	caps := make([]int, 2 * (ncaps + 1), re.allocator)
	defer delete(caps, re.allocator)

	// VM scratch 在整个调用内复用（每个起点重置 last_sp）
	scratch: VM_Scratch
	defer vm_scratch_destroy(re, &scratch)
	vm_scratch_ensure(re, &scratch)

	pos := 0
	prev_match_end := -1 // Go allMatches：空匹配起点恰为上一匹配终点 → 丢弃
	for pos <= len(data) {
		matched := false
		if re.literal != nil {
			idx := literal_index(re, data, pos)
			if idx >= 0 {
				caps[0] = idx
				caps[1] = idx + len(re.literal)
				matched = true
			}
	} else {
		// 前导字面量的作用：把"每个字节都跑一次 VM"变成"只在前导串命中处跑"，
		// 这对 `foo\d+` 这类半字面模式在长行上的扫描是决定性的。
		// prefix_next_candidate 只返回可能开始的起点 —— 跳过的那些位置
		// 必然无法产生匹配（任何匹配都以该字节串开头），因此结果与穷举一致。
		if re.prefix != nil && !prefix_at(re, data, pos) {
			cand := prefix_next_candidate(re, data, pos + 1)
			if cand < 0 {
				break
			}
			pos = cand
			continue
		}
		matched = vm_run_scratch(re, &scratch, data, pos, caps)
	}
	if !matched {
		// 字面量路径已向前搜索（miss 即没有更多命中）；VM 路径是
		// 锚定匹配，未命中只需前移一个起点继续扫。
		if re.literal != nil {
			break
		}
		if re.prefix != nil && pos < len(data) {
			// 刚刚那个候选起点不匹配前缀之后的位置；这里必须 +1，
			// 否则下一次循环还会停在同一个候选上（死循环）。
			cand := prefix_next_candidate(re, data, pos + 1)
			if cand < 0 {
				break
			}
			pos = cand
			continue
		}
		pos += 1
		continue
	}
		start, end := caps[0], caps[1]
		if start < 0 || end < start || end > len(data) {
			return out, false // 防御：不应发生
		}
		// Go allMatches 语义：空匹配（VM 锚定时 start==pos）若起点恰为
		// 上一匹配终点则跳过（仅推进扫描点）；prev_match_end 每条都更新。
		accept := true
		if end == pos && start == prev_match_end {
			accept = false
		}
		if accept {
			m := Match{start = start, end = end}
			if ncaps > 0 {
				m.groups = make([]int, 2 * (ncaps + 1), re.allocator)
				copy(m.groups, caps)
			}
			append(&out, m)
			if first_only {
				break
			}
		}
		prev_match_end = end
		// 推进：空匹配前移一字节；非空跳到匹配终点（= Go 的 max(a[1], pos+1)）
		if end == pos {
			pos += 1
		} else {
			pos = end
		}
	}
	return out, true
}

// ---------------------------------------------------------------------------
// 回溯 VM
// ---------------------------------------------------------------------------

Frame :: struct {
	pc:       int,
	sp:       int,
	undo_top: int,
}

Undo :: struct {
	slot: int,
	val:  int,
}

// 可复用的 VM 临时状态（栈 / 撤销日志 / 无进展检测表）。
VM_Scratch :: struct {
	stack:    [dynamic]Frame,
	undo_log: [dynamic]Undo,
	last_sp:  []int,
}

vm_scratch_ensure :: proc(re: ^Regex, s: ^VM_Scratch) {
	if len(s.last_sp) < len(re.prog) {
		delete(s.last_sp, re.allocator)
		s.last_sp = make([]int, len(re.prog), re.allocator)
	}
}

vm_scratch_destroy :: proc(re: ^Regex, s: ^VM_Scratch) {
	delete_dynamic_array(s.stack)
	delete_dynamic_array(s.undo_log)
	delete(s.last_sp, re.allocator)
	s^ = {}
}

// 从 start 位置尝试匹配。命中时 caps 已填好（caps[0]/caps[1] 为整匹配区间）。
vm_run :: proc(re: ^Regex, data: []u8, start: int, caps: []int) -> bool {
	scratch: VM_Scratch
	defer vm_scratch_destroy(re, &scratch)
	vm_scratch_ensure(re, &scratch)
	return vm_run_scratch(re, &scratch, data, start, caps)
}

// 无进展循环裁剪：同一 (pc, sp) 重复到达说明进入空转循环，直接剪枝——
// 只走退出分支。对无反向引用的模式这是严格的记忆化（可匹配性只依赖
// pc/sp）；含反向引用时存在极端语义风险（README 已知行为 #5）。
vm_run_scratch :: proc(re: ^Regex, s: ^VM_Scratch, data: []u8, start: int, caps: []int) -> bool {
	prog := re.prog
	ncaps := len(caps)

	clear(&s.stack)
	clear(&s.undo_log)
	for i in 0..<len(s.last_sp) {
		s.last_sp[i] = -1
	}
	for i in 0..<ncaps {
		caps[i] = -1
	}

	pc := 0
	sp := start
	steps := 0

	for {
		steps += 1
		if steps > MAX_STEPS_PER_START {
			return false
		}
		inst := prog[pc]
		advanced := true
		switch inst.op {
		case .Char:
			if sp >= len(data) {
				advanced = false
			} else {
				c := data[sp]
				if inst.ci {
					c = lower_ascii(c)
				}
				if c != inst.ch {
					advanced = false
				} else {
					sp += 1
					pc += 1
				}
			}
		case .Any:
			if sp >= len(data) || (!inst.dot_all && data[sp] == '\n') {
				advanced = false
			} else {
				sp += 1
				pc += 1
			}
		case .Class:
			if sp >= len(data) {
				advanced = false
			} else {
				c := data[sp]
				if inst.ci {
					c = lower_ascii(c)
				}
				if !class_contains(re.classes[inst.x], c) {
					advanced = false
				} else {
					sp += 1
					pc += 1
				}
			}
		case .Save:
			append(&s.undo_log, Undo{slot = inst.x, val = caps[inst.x]})
			caps[inst.x] = sp
			pc += 1
		case .Split:
			if s.last_sp[pc] == sp {
				// 无进展：只走退出分支（贪婪 Split 退出在 y，懒惰在 x）
				if inst.lazy {
					pc = inst.x
				} else {
					pc = inst.y
				}
			} else {
				s.last_sp[pc] = sp
				append(&s.stack, Frame{pc = inst.y, sp = sp, undo_top = len(s.undo_log)})
				pc = inst.x
			}
		case .Jmp:
			pc = inst.x
		case .Match:
			caps[1] = sp
			return true
		case .Bol:
			if sp != 0 {
				advanced = false
			} else {
				pc += 1
			}
		case .Eol:
			if sp != len(data) {
				advanced = false
			} else {
				pc += 1
			}
		case .Text_Start:
			if sp != 0 {
				advanced = false
			} else {
				pc += 1
			}
		case .Text_End:
			if sp != len(data) {
				advanced = false
			} else {
				pc += 1
			}
		case .Word_B:
			l := sp > 0 && is_word_byte(data[sp - 1])
			r := sp < len(data) && is_word_byte(data[sp])
			if l == r {
				advanced = false
			} else {
				pc += 1
			}
		case .Not_Word_B:
			l := sp > 0 && is_word_byte(data[sp - 1])
			r := sp < len(data) && is_word_byte(data[sp])
			if l != r {
				advanced = false
			} else {
				pc += 1
			}
		case .Backref:
			g := inst.x
			gs := caps[2 * g]
			ge := caps[2 * g + 1]
			if gs < 0 || ge < 0 {
				advanced = false
			} else {
				n := ge - gs
				if sp + n > len(data) || !bytes.equal(data[sp:sp + n], data[gs:ge]) {
					advanced = false
				} else {
					sp += n
					pc += 1
				}
			}
		}

		if !advanced {
			// 回溯：弹栈 → 撤销 Save → 恢复 (pc, sp)
			for {
				if len(s.stack) == 0 {
					return false
				}
				f := pop(&s.stack)
				for len(s.undo_log) > f.undo_top {
					u := pop(&s.undo_log)
					caps[u.slot] = u.val
				}
				pc = f.pc
				sp = f.sp
				// 恢复到的帧又是无进展状态 → 继续向上回溯
				if prog[pc].op != .Split || s.last_sp[pc] != sp {
					break
				}
			}
		}
	}
}

is_word_byte :: proc "contextless" (c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

lower_ascii :: proc "contextless" (c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + 32
	}
	return c
}

upper_ascii :: proc "contextless" (c: u8) -> u8 {
	if c >= 'a' && c <= 'z' {
		return c - 32
	}
	return c
}

// ---------------------------------------------------------------------------
// 字面量快路径
// ---------------------------------------------------------------------------

literal_index :: proc(re: ^Regex, data: []u8, from: int) -> int {
	if from > len(data) || len(re.literal) == 0 {
		return -1
	}
	if !re.ci_literal {
		idx := bytes.index(data[from:], re.literal)
		if idx < 0 {
			return -1
		}
		return idx + from
	}
	limit := len(data) - len(re.literal)
	for i := from; i <= limit; i += 1 {
		found := true
		for j in 0..<len(re.literal) {
			if lower_ascii(data[i + j]) != re.literal[j] {
				found = false
				break
			}
		}
		if found {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// 替换
// ---------------------------------------------------------------------------

// ReplaceAll 语义：$1/$2/${name}/$$ 展开；未参与组 → 空串。
// changed 表示是否发生过替换（内容可能不变，如替换串等于原文）。
// 推进与空匹配抑制规则对齐 Go regexp.replaceAll（见 /usr/local/go/src/regexp/regexp.go）：
//   - 间隙文本按「上一匹配终点」游标拷贝，而非扫描点（VM 逐点扫描会越过间隙）
//   - 空匹配紧邻上一匹配终点（且起点非 0）时不插入替换
//   - 扫描点推进 = max(匹配终点, 扫描点+1)
regex_replace_all :: proc(re: ^Regex, data: []u8, template: string) -> (out: []u8, changed: bool) {
	out_buf: [dynamic]u8
	last_match_end := 0 // 已拷贝到输出的数据终点
	pos := 0           // 扫描起点
	caps := make([]int, 2 * (re.ngroups + 1), re.allocator)
	defer delete(caps, re.allocator)
	for pos <= len(data) {
		matched := false
		if re.literal != nil {
			idx := literal_index(re, data, pos)
			if idx >= 0 {
				caps[0] = idx
				caps[1] = idx + len(re.literal)
				matched = true
			}
		} else {
			matched = vm_run(re, data, pos, caps)
		}
		if !matched {
			// 同 find_all_impl：字面量路径前向搜索过，VM 路径需逐起点推进
			if re.literal != nil {
				break
			}
			pos += 1
			continue
		}
		start, end := caps[0], caps[1]
		// 匹配前的未匹配文本（游标=上一匹配终点）
		append(&out_buf, ..data[last_match_end:start])
		// Go：空匹配紧邻上一匹配终点且不在位置 0 → 不插入替换
		if end > last_match_end || start == 0 {
			expand_template(re, template, data, caps, &out_buf)
			changed = true
		}
		last_match_end = end
		if end == pos {
			pos += 1
		} else {
			pos = end
		}
	}
	if last_match_end < len(data) {
		append(&out_buf, ..data[last_match_end:])
	}
	return out_buf[:], changed
}

// $1 / $2 / ${1} / $name / ${name} / $$ 展开（Go regexp.expand 逐行对齐）。
//
// Go 的取号规则（extract）：`$` 后吃**最长**的 [A-Za-z0-9_] 串；
// 全数字才算组号（且禁止前导零，如 $01 视为名字）；否则按**命名组**处理，
// 名字不存在 → 展开为空。范围越界同样展开为空，**没有**单数字回退
// （实测：`$12` 在只有 2 个组的模式上得到空串，不是组 1）。
// 括号形态 `${...}` 必须闭合，否则 `$` 原样输出。
expand_template :: proc(re: ^Regex, template: string, data: []u8, caps: []int, out: ^[dynamic]u8) {
	t := template
	for len(t) > 0 {
		idx := strings.index_byte(t, '$')
		if idx < 0 {
			append(out, ..transmute([]u8)t)
			break
		}
		append(out, ..transmute([]u8)t[:idx])
		t = t[idx:] // t[0] == '$'
		if len(t) >= 2 && t[1] == '$' {
			append(out, '$') // $$ → $
			t = t[2:]
			continue
		}
		num, name, rest, ok := extract_group_ref(t[1:])
		if !ok {
			append(out, '$') // 畸形引用：$ 当普通字符
			t = t[1:]
			continue
		}
		t = rest
		g := -1
		if num >= 0 {
			g = num
		} else {
			// 命名组：查 subexp 名字表
			if idx, found := group_index(re, name); found {
				g = idx
			}
		}
		if g >= 0 && 2*g+1 < len(caps) && caps[2*g] >= 0 {
			append(out, ..data[caps[2*g]:caps[2*g+1]])
		}
	}
}

// extract_group_ref — Go regexp.extract 的移植：解析 `$` 之后的部分。
//
//	{name}   花括号形态，必须闭合
//	name     最长 [A-Za-z0-9_]+ 串（Go 用 unicode 字母；这里只认 ASCII，
//	         见文件头"与 Go 的已知差异"）
//
// 全数字（无前导零、<1e8）→ num 为组号；否则 num = -1，name 为组名。
// 返回 rest 为消费后的剩余模板；ok = false 表示畸形（调用方把 $ 原样输出）。
extract_group_ref :: proc(s: string) -> (num: int, name: string, rest: string, ok: bool) {
	if len(s) == 0 {
		return 0, "", s, false
	}
	brace := false
	i := 0
	if s[0] == '{' {
		brace = true
		i = 1
	}
	start := i
	for i < len(s) {
		c := s[i]
		is_alnum := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if !is_alnum {
			break
		}
		i += 1
	}
	if i == start {
		return 0, "", s, false // 空名字不合法
	}
	name = s[start:i]
	if brace {
		if i >= len(s) || s[i] != '}' {
			return 0, "", s, false // 缺右括号
		}
		i += 1
	}

	// 数字判定（Go：逐位累加，遇非数字或超 1e8 即否；禁止前导零）
	all_digits := true
	n := 0
	for k in 0..<len(name) {
		if name[k] < '0' || name[k] > '9' || n >= 100_000_000 {
			all_digits = false
			break
		}
		n = n*10 + int(name[k] - '0')
	}
	if len(name) > 1 && name[0] == '0' {
		all_digits = false
	}
	if all_digits {
		return n, name, s[i:], true
	}
	return -1, name, s[i:], true
}

// 组名 → 组号（只查命名组表）。
// 数字形态由 extract_group_ref 在展开前判定，不走这里——否则 "$01"
// 会被误当成组 1（Go 把前导零形态视为**名字**，查不到即展开为空）。
group_index :: proc(re: ^Regex, name: string) -> (int, bool) {
	for n, i in re.group_names {
		if i > 0 && n == name {
			return i, true
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// 内存管理
// ---------------------------------------------------------------------------

regex_free_matches :: proc(re: ^Regex, ms: ^[dynamic]Match) {
	for m in ms {
		if m.groups != nil {
			delete(m.groups, re.allocator)
		}
	}
	delete_dynamic_array(ms^)
	ms^ = {}
}

free_node :: proc(n: ^Node, allocator: runtime.Allocator) {
	if n == nil {
		return
	}
	#partial switch n.kind {
	case .Concat, .Alternate:
		for kid in n.kids {
			free_node(kid, allocator)
		}
		delete_dynamic_array(n.kids)
	case .Repeat, .Group:
		free_node(n.sub, allocator)
	case .Class:
		delete(n.class.ranges, allocator)
	}
	free(n, allocator)
}

delete_nodes :: proc(ns: []^Node, allocator: runtime.Allocator) {
	for n in ns {
		free_node(n, allocator)
	}
}

// ---------------------------------------------------------------------------
// 字面量转义（-F / FixedString 支持）
// ---------------------------------------------------------------------------

// regex_quote_meta — 复刻 Go regexp.QuoteMeta：把正则元字符前加 '\'，
// 使其按字面量匹配。元字符集与 Go 完全一致（specialBytes 初始化表）：
//
//	\ . + * ? ( ) | [ ] { } ^ $
//
// 用途：find/replace/rename 的 -F（FixedString）选项——gx 的做法就是
// `pattern = regexp.QuoteMeta(pattern)` 后再编译。本引擎的 parse_escape
// 对 `\<元字符>` 一律回落为字面量字符（case: 分支 → unescape_char），
// 因此这 14 个字符的转义形态均可被正确解析。
//
// 返回堆字符串（context.allocator），调用方负责 delete。
regex_quote_meta :: proc(s: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$':
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b) // 所有权转移
}
