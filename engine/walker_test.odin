package engine

// ============================================================================
// walker_test.odin — 遍历行为测试（逐条对齐 gx walker）
//
// 策略：在 /tmp 下搭 fixture 目录树 → walk → 断言产出路径序列。
// 每个测试用独立基目录（odin test 默认多线程并行，避免相互干扰）。
// fixture 清理用 walk 自身完成（顺带狗粮测试 include_dir 产出）。
//
// 分配器约定：路径拼接等一次性字符串一律走 context.temp_allocator
// （Odin 测试运行器在每个测试结束后 free_all，无需手动 delete）。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "odd:lib"

// 字符串 → []u8 视图（Odin 无 []u8("literal") 语法）。
b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// 测试基目录（各测试不同，避免并行竞争）。
BASE_BASIC    :: "/tmp/odd_test_walk_basic"
BASE_SKIP     :: "/tmp/odd_test_walk_skip"
BASE_GITIGN   :: "/tmp/odd_test_walk_gitignore"
BASE_BIN      :: "/tmp/odd_test_walk_binary"
BASE_SYMLINK  :: "/tmp/odd_test_walk_symlink"
BASE_GLOB     :: "/tmp/odd_test_walk_glob"
BASE_DEPTH    :: "/tmp/odd_test_walk_depth"
BASE_FILEROOT :: "/tmp/odd_test_walk_fileroot"
BASE_ORDER    :: "/tmp/odd_test_walk_order"
BASE_EMPTY    :: "/tmp/odd_test_walk_empty"

// 拼路径（临时分配器，随测试结束自动回收）。
pjoin :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

// 建文件（content 为字面量时零拷贝视图即可）。
mkfile :: proc(path: string, content: string) -> bool {
	return os.write_entire_file(path, b(content), os.perm_number(0o644)) == nil
}

// 建目录。
mkdir :: proc(path: string) -> bool {
	return os.make_directory(path, os.perm_number(0o755)) == nil
}

// 递归强制删除（测试清理专用）。
// 不能用 walk 做清理：walk 默认跳过 .git/build 等目录、且受 .gitignore
// 过滤，skip 目录测试的 fixture 永远清不掉。这里直接读目录递归。
rm_rf :: proc(path: string) {
	fi, err := os.lstat(path, context.allocator)
	if err != nil {
		return
	}
	defer os.file_info_delete(fi, context.allocator)
	if fi.type == .Directory {
		f, oerr := os.open(path, os.O_RDONLY)
		if oerr != nil {
			return
		}
		infos, rerr := os.read_dir(f, -1, context.temp_allocator)
		os.close(f)
		if rerr != nil {
			return
		}
		for cfi in infos {
			child, jerr := filepath.join({path, cfi.name}, context.temp_allocator)
			if jerr == nil {
				rm_rf(child)
			}
		}
		for cfi in infos {
			os.file_info_delete(cfi, context.temp_allocator)
		}
		delete(infos, context.temp_allocator)
	}
	os.remove(path)
}

// 清理基目录（rm_rf 的语义化别名）。
cleanup_tree :: proc(base: string) {
	rm_rf(base)
}

// 提取产出路径序列（借用 entry 内存，随 res 存活）。
entry_paths :: proc(res: ^Walk_Result) -> (out: [dynamic]string) {
	for e in res.entries {
		append(&out, e.path)
	}
	return
}

// 断言路径序列完全相等。
// 注意：got 是调用方动态数组的切片视图，所有权归调用方——本 proc 只读不删，
// 否则调用方再 delete(got) 会双重释放（delete_slice 与 delete_dynamic_array
// 释放同一块后备内存）。
expect_paths :: proc(t: ^testing.T, got: []string, want: []string) {
	testing.expectf(t, len(got) == len(want), "条数不符 got=%v want=%v", got, want)
	if len(got) != len(want) {
		return
	}
	for i in 0..<len(got) {
		testing.expectf(t, got[i] == want[i], "第 %d 条: got %q want %q", i, got[i], want[i])
	}
}

// 单次 walk + 断言的一站式助手。want 里的路径相对 base，内部拼成绝对路径。
walk_and_expect :: proc(t: ^testing.T, base: string, cfg_over: Walker_Config, want: []string) {
	cfg := cfg_over
	cfg.paths = {base}
	cfg.allocator = context.allocator
	res := walk(cfg)
	defer walk_result_destroy(&res)
	got := entry_paths(&res)
	abs_want := make([]string, len(want), context.temp_allocator)
	for i in 0..<len(want) {
		abs_want[i] = pjoin({base, want[i]})
	}
	expect_paths(t, got[:], abs_want)
	delete(got) // got 是本 proc 建的动态数组，断言用完即释放
}

@(test)
test_walk_basic_order :: proc(t: ^testing.T) {
	base := BASE_BASIC
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "b.md"}), "x\n"), "建 b.md")
	testing.expect(t, mkfile(pjoin({base, "a.txt"}), "x\n"), "建 a.txt")
	testing.expect(t, mkdir(pjoin({base, "sub"})), "建 sub")
	testing.expect(t, mkfile(pjoin({base, "sub", "c.txt"}), "x\n"), "建 sub/c.txt")

	// 默认（不含目录）：字典序，目录递归夹在中间
	walk_and_expect(t, base, Walker_Config{}, {"a.txt", "b.md", "sub/c.txt"})

	// 含目录：根在最前，目录条目先于其子条目
	walk_and_expect(t, base, Walker_Config{include_dir = true}, {".", "a.txt", "b.md", "sub", "sub/c.txt"})
}

@(test)
test_walk_default_skip_dirs :: proc(t: ^testing.T) {
	base := BASE_SKIP
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "keep.txt"}), "x\n"), "建 keep.txt")
	skip_dirs := []string{"build", "node_modules", ".git", "vendor", "target", ".idea", ".vscode", ".hg", ".svn"}
	for d in skip_dirs {
		testing.expect(t, mkdir(pjoin({base, d})), "建跳过目录")
		testing.expect(t, mkfile(pjoin({base, d, "inner.txt"}), "x\n"), "建跳过目录内文件")
	}
	walk_and_expect(t, base, Walker_Config{}, {"keep.txt"})

	// 根本身叫 build → 整个根被跳过（gx：SkipDirs 检查先于一切，含根本身）
	base2 := pjoin({base, "build"})
	res2 := walk(Walker_Config{paths = {base2}, allocator = context.allocator})
	defer walk_result_destroy(&res2)
	testing.expectf(t, len(res2.entries) == 0, "根名为 build 应被跳过, got %d 条", len(res2.entries))
}

@(test)
test_walk_gitignore :: proc(t: ^testing.T) {
	base := BASE_GITIGN
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, ".gitignore"}), "*.log\nignored_dir/\n!keep.log\n"), "建 .gitignore")
	testing.expect(t, mkfile(pjoin({base, "a.txt"}), "x\n"), "建 a.txt")
	testing.expect(t, mkfile(pjoin({base, "b.log"}), "x\n"), "建 b.log")
	testing.expect(t, mkfile(pjoin({base, "keep.log"}), "x\n"), "建 keep.log")
	testing.expect(t, mkdir(pjoin({base, "ignored_dir"})), "建 ignored_dir")
	testing.expect(t, mkfile(pjoin({base, "ignored_dir", "x.txt"}), "x\n"), "建 ignored_dir/x.txt")
	testing.expect(t, mkdir(pjoin({base, "sub"})), "建 sub")
	testing.expect(t, mkfile(pjoin({base, "sub", ".gitignore"}), "*.tmp\n"), "建 sub/.gitignore")
	testing.expect(t, mkfile(pjoin({base, "sub", "c.tmp"}), "x\n"), "建 sub/c.tmp")
	testing.expect(t, mkfile(pjoin({base, "sub", "d.txt"}), "x\n"), "建 sub/d.txt")
	// 父级规则的取反（!keep.log）优先；.gitignore 自身永不忽略；子级规则独立生效。
	// 注意默认配置不产目录条目，want 里只有文件。
	walk_and_expect(t, base, Walker_Config{}, {
		".gitignore", "a.txt", "keep.log", "sub/.gitignore", "sub/d.txt",
	})
	// --all：忽略 .gitignore，全部文件产出（字典序；仍不含目录条目）
	walk_and_expect(t, base, Walker_Config{ignore_gitignore = true}, {
		".gitignore", "a.txt", "b.log", "ignored_dir/x.txt", "keep.log",
		"sub/.gitignore", "sub/c.tmp", "sub/d.txt",
	})
	// 含目录 + gitignore：目录条目也按规则过滤（ignored_dir 不产出）。
	// 注意 include_dir=true 时根条目 "." 在最前（gx：根目录自身也作为条目产出）。
	walk_and_expect(t, base, Walker_Config{include_dir = true}, {
		".", ".gitignore", "a.txt", "keep.log", "sub", "sub/.gitignore", "sub/d.txt",
	})
}

@(test)
test_walk_binary :: proc(t: ^testing.T) {
	base := BASE_BIN
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "text.txt"}), "plain text\n"), "建 text.txt")
	testing.expect(t, mkfile(pjoin({base, "bin.dat"}), "abc\x00def"), "建 bin.dat")
	// NUL 在第 600 字节（前 512 干净）→ 不算二进制（gx 同款 512 字节启发式）
	// 注意：aprintf 的 allocator 必须用命名实参——位置实参会被 ..any 变参吞掉，
	// 既渲染出 "%!(EXTRA ...)" 垃圾内容，又落到 context.allocator 造成泄漏。
	long := strings.repeat("a", 600, context.temp_allocator)
	far := fmt.aprintf("%s\x00", long, allocator = context.temp_allocator)
	testing.expect(t, mkfile(pjoin({base, "far.dat"}), far), "建 far.dat")

	walk_and_expect(t, base, Walker_Config{skip_binary = true}, {"far.dat", "text.txt"})
	walk_and_expect(t, base, Walker_Config{}, {"bin.dat", "far.dat", "text.txt"})
}

@(test)
test_walk_symlink :: proc(t: ^testing.T) {
	base := BASE_SYMLINK
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "a.txt"}), "x\n"), "建 a.txt")
	testing.expect(t, mkdir(pjoin({base, "sub"})), "建 sub")
	testing.expect(t, mkfile(pjoin({base, "sub", "c.txt"}), "x\n"), "建 sub/c.txt")
	testing.expect(t, os.symlink("a.txt", pjoin({base, "link.txt"})) == nil, "建文件链接")
	testing.expect(t, os.symlink("sub", pjoin({base, "dlink"})) == nil, "建目录链接")

	// 默认：符号链接不产出、不跟随
	walk_and_expect(t, base, Walker_Config{}, {"a.txt", "sub/c.txt"})
	// include_symlink：产出链接自身（size = 目标路径长度），不递归链接目标
	walk_and_expect(t, base, Walker_Config{include_symlink = true}, {
		"a.txt", "dlink", "link.txt", "sub/c.txt",
	})
	// 目录链接在 include_dir 下也不展开（Go WalkDir 语义）
	walk_and_expect(t, base, Walker_Config{include_dir = true, include_symlink = true}, {
		".", "a.txt", "dlink", "link.txt", "sub", "sub/c.txt",
	})
	// 校验链接条目字段
	cfg := Walker_Config{include_symlink = true, allocator = context.allocator}
	cfg.paths = {base}
	res := walk(cfg)
	defer walk_result_destroy(&res)
	found := false
	for e in res.entries {
		if e.name == "link.txt" {
			found = true
			testing.expect(t, e.is_symlink, "link.txt 应标记为符号链接")
			testing.expectf(t, e.size == 5, "链接 size 应为目标名长度 5, got %d", e.size)
			testing.expect(t, !e.is_dir, "链接不是目录")
		}
	}
	testing.expect(t, found, "应找到 link.txt")
}

@(test)
test_walk_glob :: proc(t: ^testing.T) {
	base := BASE_GLOB
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "a.txt"}), "x\n"), "建 a.txt")
	testing.expect(t, mkfile(pjoin({base, "b.md"}), "x\n"), "建 b.md")
	testing.expect(t, mkdir(pjoin({base, "sub"})), "建 sub")
	testing.expect(t, mkfile(pjoin({base, "sub", "c.txt"}), "x\n"), "建 sub/c.txt")
	testing.expect(t, mkfile(pjoin({base, "sub", "d.md"}), "x\n"), "建 sub/d.md")
	// glob 只过滤普通文件；符号链接不受影响（gx 在 glob 之前就 return 了链接）
	testing.expect(t, os.symlink("a.txt", pjoin({base, "link.md"})) == nil, "建 link.md")

	walk_and_expect(t, base, Walker_Config{file_pattern = "*.txt"}, {"a.txt", "sub/c.txt"})
	walk_and_expect(t, base, Walker_Config{file_pattern = "*.txt", include_symlink = true}, {
		"a.txt", "link.md", "sub/c.txt",
	})
}

@(test)
test_walk_depth :: proc(t: ^testing.T) {
	base := BASE_DEPTH
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	testing.expect(t, mkfile(pjoin({base, "a.txt"}), "x\n"), "建 a.txt")
	testing.expect(t, mkdir(pjoin({base, "sub"})), "建 sub")
	testing.expect(t, mkfile(pjoin({base, "sub", "b.txt"}), "x\n"), "建 sub/b.txt")
	testing.expect(t, mkdir(pjoin({base, "sub", "deep"})), "建 sub/deep")
	testing.expect(t, mkfile(pjoin({base, "sub", "deep", "c.txt"}), "x\n"), "建 sub/deep/c.txt")

	// gx 深度公式按「路径分量数差」计算：绝对根 "/tmp/x" 有 3 个分量，
	// 直接子级深度 1、孙子级 2、曾孙级 3。max_depth=N 即保留深度 <= N。
	walk_and_expect(t, base, Walker_Config{max_depth = 1}, {"a.txt"})
	walk_and_expect(t, base, Walker_Config{max_depth = 2}, {"a.txt", "sub/b.txt"})
	walk_and_expect(t, base, Walker_Config{max_depth = 3}, {"a.txt", "sub/b.txt", "sub/deep/c.txt"})

	// 注：gx 的 "." 根怪癖（子条目深度 0，max_depth=1 可到孙子级）依赖进程
	// CWD，并行测试下 chdir 有竞争，改由 tests/run.sh 差分用例覆盖。
}

@(test)
test_walk_file_root :: proc(t: ^testing.T) {
	base := BASE_FILEROOT
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	target := pjoin({base, "a.txt"})
	testing.expect(t, mkfile(target, "x\n"), "建 a.txt")
	// 根是文件：只走该文件的「非目录」分支
	res := walk(Walker_Config{paths = {target}, allocator = context.allocator})
	defer walk_result_destroy(&res)
	got := entry_paths(&res)
	expect_paths(t, got[:], {target})
	delete(got)
	// 根是文件且不匹配 glob → 无产出
	res2 := walk(Walker_Config{paths = {target}, file_pattern = "*.md", allocator = context.allocator})
	defer walk_result_destroy(&res2)
	testing.expectf(t, len(res2.entries) == 0, "glob 不匹配应无产出, got %d", len(res2.entries))
	// 不存在的根：静默无产出（gx：WalkDir 错误回调被跳过）
	res3 := walk(Walker_Config{paths = {pjoin({base, "nope"})}, allocator = context.allocator})
	defer walk_result_destroy(&res3)
	testing.expectf(t, len(res3.entries) == 0, "不存在的根应无产出, got %d", len(res3.entries))
}

@(test)
test_walk_lexical_order :: proc(t: ^testing.T) {
	base := BASE_ORDER
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建基目录")
	// 字节序：数字 < 大写 < '_'(0x5F) < 小写。
	// 注意：不能同时用 "Z.txt" 和 "z.txt" —— macOS APFS 默认大小写不敏感，
	// 二者是同一个文件（readdir 只会看到一个）。用 "zz.txt" 代替。
	names := []string{"B.txt", "a.txt", "1.txt", "_x.txt", "Z.txt", "zz.txt"}
	for n in names {
		testing.expect(t, mkfile(pjoin({base, n}), "x\n"), "建文件")
	}
	want := []string{"1.txt", "B.txt", "Z.txt", "_x.txt", "a.txt", "zz.txt"}
	walk_and_expect(t, base, Walker_Config{}, want)
}

@(test)
test_walk_empty_dir :: proc(t: ^testing.T) {
	base := BASE_EMPTY
	cleanup_tree(base)
	defer cleanup_tree(base)
	testing.expect(t, mkdir(base), "建空目录")
	// 空目录：无产出（默认不含目录）
	walk_and_expect(t, base, Walker_Config{}, {})
	// 含目录时只产出根本身
	walk_and_expect(t, base, Walker_Config{include_dir = true}, {"."})
}
