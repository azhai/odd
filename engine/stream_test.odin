package engine

// ============================================================================
// stream_test.odin — 统一输入测试
//
// stdin 实读依赖管道（由 tests/run.sh 的 shell 层覆盖），这里测判定逻辑
// 与文件读取路径。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:testing"

STREAM_BASE :: "/tmp/odd_test_stream"

// 注意：aprintf 的 allocator 必须用命名实参——位置实参会被 ..any 变参吞掉
// （内容混入 "%!(EXTRA ...)" 且分配落到 context.allocator）。
@(test)
test_is_stdin :: proc(t: ^testing.T) {
	testing.expect(t, is_stdin(nil), "空 paths → stdin")
	testing.expect(t, is_stdin({}), "空切片 → stdin")
	testing.expect(t, is_stdin({"-"}), "单个 - → stdin")
	testing.expect(t, !is_stdin({"a.txt"}), "单文件 → 非 stdin")
	testing.expect(t, !is_stdin({"-", "b"}), "- 加其他 → 非 stdin（gx：仅恰一个 -）")
	testing.expect(t, !is_stdin({"a", "-"}), "其他加 - → 非 stdin")
}

@(test)
test_read_all_file :: proc(t: ^testing.T) {
	base := STREAM_BASE
	// 平铺目录：逐个删文件再删目录
	if os.exists(base) {
		os.remove(fmt.aprintf("%s/data.txt", base, allocator = context.temp_allocator))
		os.remove(fmt.aprintf("%s/empty.txt", base, allocator = context.temp_allocator))
		os.remove(base)
	}
	testing.expect(t, os.make_directory(base, os.perm_number(0o755)) == nil, "建目录")
	defer {
		os.remove(fmt.aprintf("%s/data.txt", base, allocator = context.temp_allocator))
		os.remove(fmt.aprintf("%s/empty.txt", base, allocator = context.temp_allocator))
		os.remove(base)
	}
	path := fmt.aprintf("%s/data.txt", base, allocator = context.temp_allocator)
	content := "line1\nline2\n"
	testing.expect(t, os.write_entire_file(path, b(content), os.perm_number(0o644)) == nil, "写文件")

	data, name, ok := read_all({path}, context.allocator)
	testing.expect(t, ok, "读取应成功")
	testing.expectf(t, name == path, "name 应为路径本身, got %q", name)
	testing.expectf(t, string(data) == content, "内容不符: %q", string(data))
	defer delete(data, context.allocator)

	// 空文件：成功但内容为空
	empty := fmt.aprintf("%s/empty.txt", base, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(empty, []u8{}, os.perm_number(0o644)) == nil, "写空文件")
	data2, name2, ok2 := read_all({empty}, context.allocator)
	testing.expect(t, ok2 && len(data2) == 0, "空文件应读出空内容")
	testing.expectf(t, name2 == empty, "空文件 name 不符, got %q", name2)
	defer delete(data2, context.allocator)
}

@(test)
test_read_all_missing :: proc(t: ^testing.T) {
	path := fmt.aprintf("%s/definitely-not-here.txt", STREAM_BASE, allocator = context.temp_allocator)
	_, _, ok := read_all({path}, context.allocator)
	testing.expect(t, !ok, "不存在的文件应返回 ok=false")
}

@(test)
test_display_name :: proc(t: ^testing.T) {
	testing.expectf(t, display_name("-") == STDIN_NAME, "got %q", display_name("-"))
	testing.expectf(t, display_name("") == STDIN_NAME, "got %q", display_name(""))
	testing.expectf(t, display_name("a.txt") == "a.txt", "got %q", display_name("a.txt"))
}
