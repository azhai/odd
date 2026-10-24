// ============================================================================
// time_local_windows.odin — Windows 上的「本地墙上时间」换算
//
// 背景：core:sys/posix 虽然在所有目标上都能通过编译，但它并不导出
// localtime_r / mktime / time_t / tm（Windows 目标实测：
// "Error: 'time_t' is not declared by 'posix'"）。所以本地时间换算必须
// 按平台分文件实现，unix 侧见 time_local_unix.odin。
//
// Windows 侧走 Win32 API：
//   epoch → civil : 时间戳 ticks（100ns，1601 起） → FileTimeToSystemTime
//                   （得 UTC） → SystemTimeToTzSpecificLocalTime（得本地）
//   civil → epoch : TzSpecificLocalTimeToSystemTime（本地→UTC）
//                   → SystemTimeToFileTime → ticks
//
// 只声明用到的四个符号，不整体 import core:sys/windows —— 那个包把
// kernel32/user32 等全部 foreign 声明打包在内，为了两个时间函数拖进来不划算。
// 结构体也各自精简重声明（只保留我们读写的字段），ABI 布局与 Win32 一致。
//
// 语义提醒（与 unix 侧一致地"有限"）：这两个函数受构造时的时区规则支配，
// Windows 对历史日期的 DST 回溯支持有限；这是 Win32 API 的既有行为，
// 不做额外补偿。
// ============================================================================

#+build windows
package lib

import "core:time"

SYSTEMTIME :: struct {
	year:         u16,
	month:        u16,
	day_of_week:  u16,
	day:          u16,
	hour:         u16,
	minute:       u16,
	second:       u16,
	milliseconds: u16,
}

FILETIME :: struct {
	dwLowDateTime:  u32,
	dwHighDateTime: u32,
}

// 只作为不透明的入参指针出现（恒传 nil = 使用当前时区），无需列出真实字段。
TIME_ZONE_INFORMATION :: struct {}

BOOL :: i32

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	FileTimeToSystemTime            :: proc(lpFileTime: ^FILETIME, lpSystemTime: ^SYSTEMTIME) -> BOOL ---
	SystemTimeToFileTime            :: proc(lpSystemTime: ^SYSTEMTIME, lpFileTime: ^FILETIME) -> BOOL ---
	SystemTimeToTzSpecificLocalTime :: proc(
		lpTimeZoneInformation: ^TIME_ZONE_INFORMATION,
		lpUniversalTime: ^SYSTEMTIME,
		lpLocalTime: ^SYSTEMTIME,
	) -> BOOL ---
	TzSpecificLocalTimeToSystemTime :: proc(
		lpTimeZoneInformation: ^TIME_ZONE_INFORMATION,
		lpLocalTime: ^SYSTEMTIME,
		lpUniversalTime: ^SYSTEMTIME,
	) -> BOOL ---
}

// 1601-01-01（FILETIME 起点）到 1970-01-01（UNIX 起点）之间的 100ns tick 数。
FILETIME_EPOCH_TICKS :: 116_444_736_000_000_000

@(private = "file")
// UNIX 纳秒 → FILETIME tick（100ns，1601 起）。
// 负数走无符号回绕：mod 2^64 的补码加法对"结果仍为正"的 tick 值是正确的，
// 这一步之后不需要再回绕。
unix_nanos_to_filetime_ticks :: proc(ns: i64) -> u64 {
	ticks100 := ns / 100
	if ns < 0 && ns % 100 != 0 {
		ticks100 -= 1 // 向 -inf 取整，避免 1970 前的时间抖一格
	}
	return u64(ticks100) + FILETIME_EPOCH_TICKS
}

// 本地墙上时间分解（契约见 time_local_unix.odin 的同名 proc）。
local_civil :: proc(t: time.Time) -> (y, mo, d, h, mi, s: int, ok: bool) {
	ticks := unix_nanos_to_filetime_ticks(time.time_to_unix_nano(t))

	ft := FILETIME{dwLowDateTime = u32(ticks), dwHighDateTime = u32(ticks >> 32)}

	utc_st: SYSTEMTIME
	if FileTimeToSystemTime(&ft, &utc_st) == 0 {
		return 0, 0, 0, 0, 0, 0, false
	}

	local: SYSTEMTIME
	if SystemTimeToTzSpecificLocalTime(nil, &utc_st, &local) == 0 {
		// 时区换算失败就退回 UTC，而不是让整个 list 命令空掉一列
		local = utc_st
	}
	return int(local.year), int(local.month), int(local.day),
		int(local.hour), int(local.minute), int(local.second), true
}

// 本地 civil → time.Time（契约见 time_local_unix.odin 的同名 proc）。
civil_to_time :: proc(y, mo, d, h, mi, s: i64) -> time.Time {
	local_st := SYSTEMTIME {
		year   = u16(y),
		month  = u16(mo),
		day    = u16(d),
		hour   = u16(h),
		minute = u16(mi),
		second = u16(s),
	}

	utc_st: SYSTEMTIME
	if TzSpecificLocalTimeToSystemTime(nil, &local_st, &utc_st) == 0 {
		return {}
	}

	ft: FILETIME
	if SystemTimeToFileTime(&utc_st, &ft) == 0 {
		return {}
	}

	ticks := u64(ft.dwHighDateTime) << 32 | u64(ft.dwLowDateTime)
	return time.from_nanoseconds((i64(ticks) - i64(FILETIME_EPOCH_TICKS)) * 100)
}
