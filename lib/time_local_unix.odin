// ============================================================================
// time_local_unix.odin — POSIX 上的「本地墙上时间」换算
//
// 为什么必须自己写：core:time 的 date() / clock_from_time() 是 **UTC** 语义，
// 直接拿来格式化文件时间，东八区会差 8 小时。本地时间只有 libc 说得准
// （它负责 TZ 环境变量与历史 DST 规则），所以走 localtime_r / mktime。
//
// Windows 目标下 core:sys/posix 不导出这些符号，对应实现在
// time_local_windows.odin。两个文件的对外契约完全一致：
//
//   local_civil(t)   -> (y, mo, d, h, mi, s, ok)   公历完整年份（非 1900 偏移）
//   civil_to_time(..) -> time.Time                  本地时区；tm_isdst = -1
// ============================================================================

#+build darwin, linux, freebsd
package lib

import "core:sys/posix"
import "core:time"

// 本地墙上时间分解：走 libc localtime_r（自带 TZ 环境变量与 DST 规则）。
// 返回年份为公历完整年份（libc 的 tm_year 是 1900 起的偏移）。
local_civil :: proc(t: time.Time) -> (y, mo, d, h, mi, s: int, ok: bool) {
	secs := i64(time.time_to_unix_nano(t) / i64(time.Second))
	if t_ns := time.time_to_unix_nano(t); t_ns < 0 && t_ns % i64(time.Second) != 0 {
		secs -= 1 // 负时间向 -inf 取整，避免截断错位
	}
	tt := posix.time_t(secs)
	tmv: posix.tm
	if posix.localtime_r(&tt, &tmv) == nil {
		return 0, 0, 0, 0, 0, 0, false
	}
	return int(tmv.tm_year) + 1900, int(tmv.tm_mon) + 1, int(tmv.tm_mday),
		int(tmv.tm_hour), int(tmv.tm_min), int(tmv.tm_sec), true
}

// 本地 civil → time.Time：交给 libc mktime（tm_isdst = -1 让 libc 自行判断
// 是否夏令时），因此 `>=2025-01-01` 这类绝对表达式按**本地时区**解释，
// 与 Go 的 time.Parse 默认行为一致。
civil_to_time :: proc(y, mo, d, h, mi, s: i64) -> time.Time {
	tmv: posix.tm
	// darwin/linux 的 tm 字段是 c.int（i32）
	tmv.tm_year = i32(y) - 1900
	tmv.tm_mon = i32(mo) - 1
	tmv.tm_mday = i32(d)
	tmv.tm_hour = i32(h)
	tmv.tm_min = i32(mi)
	tmv.tm_sec = i32(s)
	tmv.tm_isdst = -1
	secs := posix.mktime(&tmv)
	return time.from_nanoseconds(i64(secs) * i64(time.Second))
}
