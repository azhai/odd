package lib

// ============================================================================
// sizeexpr.odin — 大小过滤表达式（复刻 gx/common/sizeexpr.go）
//
// 语法：`>1M` `<=100K` `1024` `1.5G`（运算符可省略 → 相等）。
// 单位 K/M/G 为 1024 进制；空单位为字节。
//
// 错误策略：解析只返回 ok 与否，具体错误文案由调用方包裹（含原始表达式），
// 避免在 lib 层分配错误字符串。
// ============================================================================

import "core:strconv"
import "core:strings"

Size_Filter :: struct {
	op:    Operator,
	value: i64,
}

size_match :: proc(f: Size_Filter, size: i64) -> bool {
	switch f.op {
	case .LT:
		return size < f.value
	case .LE:
		return size <= f.value
	case .GT:
		return size > f.value
	case .GE:
		return size >= f.value
	case .EQ:
		return size == f.value
	}
	return false
}

// 解析大小表达式；失败时 ok=false。
parse_size_expr :: proc(expr: string) -> (filter: Size_Filter, ok: bool) {
	if expr == "" {
		return {}, false
	}

	op, rest := parse_operator(expr)

	num_str, unit := split_number_unit(rest)
	if num_str == "" {
		return {}, false
	}

	num, num_ok := strconv.parse_f64(num_str)
	if !num_ok {
		return {}, false
	}
	if num < 0 {
		return {}, false
	}

	// 单位识别**不得分配**：这一条语句在 list 里对每文件执行一次，
	// 早前用 strings.to_upper(unit) 做大小写无关比较，每个 unit 都漏一块
	// 堆内存（lib 单测的内存追踪把它揪了出来）。手工比对 ASCII 即可。
	multiplier: i64 = 1
	switch len(unit) {
	case 0:
		multiplier = 1
	case 1:
		switch unit[0] {
		case 'k', 'K':
			multiplier = 1024
		case 'm', 'M':
			multiplier = 1024 * 1024
		case 'g', 'G':
			multiplier = 1024 * 1024 * 1024
		case:
			return {}, false
		}
	case:
		return {}, false
	}

	value := i64(num * f64(multiplier))
	return Size_Filter{op = op, value = value}, true
}

// 解析前缀运算符，返回运算符与剩余串。
parse_operator :: proc(s: string) -> (op: Operator, rest: string) {
	if strings.has_prefix(s, "<=") {
		return .LE, s[2:]
	}
	if strings.has_prefix(s, ">=") {
		return .GE, s[2:]
	}
	if strings.has_prefix(s, "<") {
		return .LT, s[1:]
	}
	if strings.has_prefix(s, ">") {
		return .GT, s[1:]
	}
	return .EQ, s
}

// 拆出前导数字与单位后缀。数字部分允许小数点（与 Go 版一致地宽松）。
split_number_unit :: proc(s: string) -> (num: string, unit: string) {
	i := 0
	if i < len(s) && s[i] == '.' {
		i += 1
	}
	for i < len(s) && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.') {
		i += 1
	}
	return s[:i], s[i:]
}
