package lib

// ============================================================================
// timeexpr.odin — 时间过滤表达式（复刻 gx/common/timeexpr.go）
//
// 语法：
//   相对  `<=1h` `>7d` `>=30m` `<=2w`（末位 s/m/h/d/w）
//   绝对  `>=2025-01-01` `>2025-01-01T12:00:00`
//
// 相对表达式的语义与 gx 一致：`<=1h` 表示"时间落在最近 1 小时内"，
// 实现为 value = now - d 且运算符取反（t >= now-d）。
// ============================================================================

import "core:strconv"
import "core:strings"
import "core:time"

Time_Filter :: struct {
	op:    Operator,
	value: time.Time,
}

time_match :: proc(f: Time_Filter, t: time.Time) -> bool {
	switch f.op {
	case .LT:
		return time_before(t, f.value)
	case .LE:
		return !time_after(t, f.value)
	case .GT:
		return time_after(t, f.value)
	case .GE:
		return !time_before(t, f.value)
	case .EQ:
		return time_diff(t, f.value) == 0
	}
	return false
}

// time_diff(a, b) = a - b。
// 注意 core:time 的 `time.diff(start, end)` 返回的是 **end - start**（与名字相反，
// 见 core/time/time.odin），这里必须换参，否则所有比较方向都会反过来。
time_diff :: proc(a, b: time.Time) -> time.Duration {
	return time.diff(b, a)
}

time_before :: proc(a, b: time.Time) -> bool {
	return time_diff(a, b) < 0
}

time_after :: proc(a, b: time.Time) -> bool {
	return time_diff(a, b) > 0
}

// 解析时间表达式；now 由调用方提供（便于测试注入）。
parse_time_expr :: proc(expr: string, now: time.Time) -> (filter: Time_Filter, ok: bool) {
	if expr == "" {
		return {}, false
	}

	op, rest := parse_operator(expr)

	if is_relative_time(rest) {
		d, d_ok := parse_relative_duration(rest)
		if !d_ok {
			return {}, false
		}
		value := time_time_add(now, -d)
		return Time_Filter{op = invert_operator(op), value = value}, true
	}

	t, t_ok := parse_absolute_time(rest)
	if !t_ok {
		return {}, false
	}
	return Time_Filter{op = op, value = t}, true
}

// 末位为时间单位字符即视为相对表达式。
is_relative_time :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	switch s[len(s) - 1] {
	case 's', 'm', 'h', 'd', 'w':
		return true
	}
	return false
}

parse_relative_duration :: proc(s: string) -> (d: time.Duration, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	unit := s[len(s) - 1]
	num_str := s[:len(s) - 1]
	num, num_ok := strconv.parse_f64(num_str)
	if !num_ok {
		return 0, false
	}
	if num < 0 {
		return 0, false
	}

	switch unit {
	case 's':
		return time.Duration(num * f64(time.Second)), true
	case 'm':
		return time.Duration(num * f64(time.Minute)), true
	case 'h':
		return time.Duration(num * f64(time.Hour)), true
	case 'd':
		return time.Duration(num * 24 * f64(time.Hour)), true
	case 'w':
		return time.Duration(num * 7 * 24 * f64(time.Hour)), true
	}
	return 0, false
}

// 相对时间要把运算符取反：`<=1h`（最近一小时）⇔ 比较对象取反为 >=。
invert_operator :: proc(op: Operator) -> Operator {
	switch op {
	case .LT:
		return .GT
	case .LE:
		return .GE
	case .GT:
		return .LT
	case .GE:
		return .LE
	case .EQ:
		return .EQ
	}
	return op
}

// 绝对时间：`YYYY-MM-DD` 或 `YYYY-MM-DDTHH:MM:SS`（本地时区，与 Go 版一致）。
parse_absolute_time :: proc(s: string) -> (t: time.Time, ok: bool) {
	if strings.contains_rune(s, 'T') {
		return parse_civil(s, true)
	}
	if strings.contains_rune(s, '-') {
		return parse_civil(s, false)
	}
	return {}, false
}

// 手工解析 civil 日期时间，转 time.Time（本地时区，见 civil_to_time）。
parse_civil :: proc(s: string, with_time: bool) -> (t: time.Time, ok: bool) {
	// 期望 "2006-01-02" 或 "2006-01-02T15:04:05"
	if len(s) < 10 {
		return {}, false
	}
	y, y_ok := strconv.parse_int(s[0:4])
	if !y_ok || s[4] != '-' {
		return {}, false
	}
	mo, mo_ok := strconv.parse_int(s[5:7])
	if !mo_ok || s[7] != '-' {
		return {}, false
	}
	d, d_ok := strconv.parse_int(s[8:10])
	if !d_ok {
		return {}, false
	}
	if mo < 1 || mo > 12 || d < 1 || d > 31 {
		return {}, false
	}

	h, mi, sec := 0, 0, 0
	if with_time {
		if len(s) < 19 || s[10] != 'T' {
			return {}, false
		}
		h, _ = strconv.parse_int(s[11:13])
		mi, _ = strconv.parse_int(s[14:16])
		sec, _ = strconv.parse_int(s[17:19])
		if h < 0 || h > 23 || mi < 0 || mi > 59 || sec < 0 || sec > 59 {
			return {}, false
		}
	}

	return civil_to_time(i64(y), i64(mo), i64(d), i64(h), i64(mi), i64(sec)), true
}

// ---------------------------------------------------------------------------
// 本机时区换算（local_civil / civil_to_time）
// ---------------------------------------------------------------------------
// 两个 proc 按平台分文件实现：
//   time_local_unix.odin     —— darwin / linux / freebsd（走 libc localtime_r / mktime）
//   time_local_windows.odin  —— windows（走 Win32 SystemTimeToTzSpecificLocalTime）
// 原因见对应文件头：posix 不导出 Windows 版的时间符号，而 core:time 的
// date() 是 UTC 语义，两者都不能一条路走到底。

// time + duration。
time_time_add :: proc(t: time.Time, d: time.Duration) -> time.Time {
	return time.time_add(t, d)
}

// time.Time → "YYYY-MM-DDTHH:MM:SS"（本地时区；Go layout "2006-01-02T15:04:05"）。
// 零值时间（gx 用 IsZero 特判）返回 19 个空格，调用方负责。
format_time_civil :: proc(t: time.Time, buf: []u8) -> string {
	y, mo, d, h, mi, s, _ := local_civil(t)
	buf[0] = '0' + u8(y / 1000 % 10)
	buf[1] = '0' + u8(y / 100 % 10)
	buf[2] = '0' + u8(y / 10 % 10)
	buf[3] = '0' + u8(y % 10)
	buf[4] = '-'
	buf[5] = '0' + u8(mo / 10)
	buf[6] = '0' + u8(mo % 10)
	buf[7] = '-'
	buf[8] = '0' + u8(d / 10)
	buf[9] = '0' + u8(d % 10)
	buf[10] = 'T'
	buf[11] = '0' + u8(h / 10)
	buf[12] = '0' + u8(h % 10)
	buf[13] = ':'
	buf[14] = '0' + u8(mi / 10)
	buf[15] = '0' + u8(mi % 10)
	buf[16] = ':'
	buf[17] = '0' + u8(s / 10)
	buf[18] = '0' + u8(s % 10)
	return string(buf[:19])
}

// 时间是否为零值（Odin 无 IsZero，用 UNIX 纳秒判定）。
time_is_zero :: proc(t: time.Time) -> bool {
	return time.time_to_unix_nano(t) == 0
}
