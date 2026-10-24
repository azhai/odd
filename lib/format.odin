package lib

// ============================================================================
// format.odin — list 命令的格式化工具（复刻 gx/common/formatutil.go）
//
// 口径与 gx 逐字对齐：
//   * FormatSize：<1K 原样字节；否则 %.1fK / %.1fM / %.1fG（1024 进制）
//   * FormatTime："2006-01-02T15:04:05"；零值 → 19 空格
//   * FormatFixedWidth：超宽截断（>3 时末尾留 "..."）；右对齐补左空格
// ============================================================================

import "core:fmt"
import "core:strings"
import "core:time"

// 列宽默认值（Mode 字段 list 未使用，保留以对齐 gx 的 ColumnWidths）。
Column_Widths :: struct {
	mode: int,
	size: int,
	time: int,
	path: int,
}

default_column_widths :: proc() -> Column_Widths {
	return Column_Widths{mode = 10, size = 10, time = 19, path = 40}
}

// ---------------------------------------------------------------------------
// 写入式 API（零分配）
// ---------------------------------------------------------------------------
// 调用方拿一个 Builder 反复复用即可——下面每个 _to 版本除了 builder 自身的
// 扩容外不产生任何临时对象。旧版实现里有两处隐藏分配：
//   * strings.repeat(" ", pad) 出来的填充串交给 aprintf 后没人释放（每格一列
//     泄漏一块）；
//   * aprintf 本身每次新建一个结果串。
// list 一行要写 4 列，旧写法是 8 次分配，新写法是 0 次。

// 定宽格式化：写入 b。value 超宽时：width>3 截断并补 "..."，否则硬截。
// align_right=true 左补空格，false 右补空格。width<=0 时不写任何内容（切片会越界）。
format_fixed_width_to :: proc(b: ^strings.Builder, value: string, width: int, align_right: bool) {
	if width <= 0 {
		return
	}
	if len(value) > width {
		if width > 3 {
			strings.write_string(b, value[:width - 3])
			strings.write_string(b, "...")
		} else {
			strings.write_string(b, value[:width])
		}
		return
	}
	pad := width - len(value)
	if align_right {
		write_spaces(b, pad)
		strings.write_string(b, value)
	} else {
		strings.write_string(b, value)
		write_spaces(b, pad)
	}
}

write_spaces :: proc(b: ^strings.Builder, n: int) {
	for _ in 0..<n {
		strings.write_byte(b, ' ')
	}
}

// 人类可读大小（1024 进制，一位小数），写入 b。
format_size_to :: proc(b: ^strings.Builder, size: i64) {
	if size < 1024 {
		fmt.sbprintf(b, "%d", size)
	} else if size < 1024 * 1024 {
		fmt.sbprintf(b, "%.1fK", f64(size) / 1024)
	} else if size < 1024 * 1024 * 1024 {
		fmt.sbprintf(b, "%.1fM", f64(size) / (1024 * 1024))
	} else {
		fmt.sbprintf(b, "%.1fG", f64(size) / (1024 * 1024 * 1024))
	}
}

// "2006-01-02T15:04:05"；零值时间 → 19 空格（与 gx 对齐），写入 b。
format_time_to :: proc(b: ^strings.Builder, t: time.Time) {
	if time_is_zero(t) {
		write_spaces(b, 19)
		return
	}
	buf: [19]u8
	strings.write_string(b, format_time_civil(t, buf[:]))
}

// ---------------------------------------------------------------------------
// 便捷封装（返回堆字符串，调用方必须 delete）
// ---------------------------------------------------------------------------
// 注意：这三个串**恒为新建**（不存在"偶尔返回入参本身"的借用情况），
// 所以无条件 delete 是安全的——旧实现会在等宽/超宽时返回入参切片，
// 调用方完全无从判断该不该释放。

format_fixed_width :: proc(value: string, width: int, align_right: bool) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	format_fixed_width_to(&b, value, width, align_right)
	return strings.to_string(b) // 转移所有权，此后不得 builder_destroy
}

format_size :: proc(size: i64) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	format_size_to(&b, size)
	return strings.to_string(b)
}

format_time :: proc(t: time.Time) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	format_time_to(&b, t)
	return strings.to_string(b)
}
