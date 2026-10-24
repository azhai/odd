package engine

// ============================================================================
// stream.odin — 统一输入：文件路径或标准输入（复刻 gx stream 包）
//
// 职责：cut/trans/script 走 stdin/stdout 管道；find/replace/list 也支持
//       "-" 读 stdin。gx 的判定：paths 为空、或恰有一个 "-" → stdin。
//
// 差异说明：gx 的 ReadAll 只读 paths[0]（多路径时取第一个）；此处照搬。
// ============================================================================

import "core:io"
import "core:os"
import "core:slice"

// stdin 的虚拟文件名（gx stream.StdinName），命中行按此名字报告。
STDIN_NAME :: "<stdin>"

// stdin 读取的缓冲块大小。
STDIN_CHUNK :: 64 * 1024

// paths 是否表示 stdin 输入（gx stream.IsStdin）。
is_stdin :: proc(paths: []string) -> bool {
	if len(paths) == 0 {
		return true
	}
	return len(paths) == 1 && paths[0] == "-"
}

// 读取全部输入内容。返回内容、展示名（stdin 时为 STDIN_NAME）、是否成功。
// 文件读取失败返回 ok=false（调用方按 gx 语义报错退出）。
read_all :: proc(paths: []string, allocator := context.allocator) -> (data: []u8, name: string, ok: bool) {
	path := "-"
	if !is_stdin(paths) {
		path = paths[0]
	}
	if path == "-" {
		buf, read_ok := read_stdin(allocator)
		if !read_ok {
			return nil, "", false
		}
		return buf, STDIN_NAME, true
	}
	file_data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return nil, "", false
	}
	return file_data, path, true
}

// 分块读 stdin 直到 EOF（os.read 到 0 字节/EOF 为止）。
read_stdin :: proc(allocator := context.allocator) -> (data: []u8, ok: bool) {
	out: [dynamic]u8
	buf := make([]u8, STDIN_CHUNK, allocator)
	defer delete(buf, allocator)
	for {
		n, err := os.read(os.stdin, buf)
		if n > 0 {
			append(&out, ..buf[:n])
		}
		if err != nil {
			if err != io.Error.EOF {
				// 真实读错误：丢弃已读内容，按失败处理
				delete_dynamic_array(out)
				return nil, false
			}
			break
		}
		if n == 0 {
			break
		}
	}
	// 移交定长切片所有权（slice.clone 后原动态数组必须显式释放）
	result := slice.clone(out[:], allocator)
	delete_dynamic_array(out)
	return result, true
}

// 展示名：stdin → STDIN_NAME；否则原路径（gx ReadAll 的 name 语义）。
display_name :: proc(path: string) -> string {
	if path == "" || path == "-" {
		return STDIN_NAME
	}
	return path
}
