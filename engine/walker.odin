package engine

// ============================================================================
// walker.odin — 目录遍历（复刻 gx walker.walkDir 的全部行为）
//
// 职责：按 gx 的规则枚举文件/目录/符号链接，产出 [dynamic]lib.File_Entry。
//
// 与 gx 的逐条对齐（含其已知怪癖）：
//   1. 顺序：根 → 子条目按**名字字典序**（Go filepath.WalkDir 排序 readdir
//      结果；Odin 的 os.read_dir 返回 getdents 原序，必须显式排序）。
//   2. 深度公式：gx 用「路径按 '/' 拆分的分量数」之差，而非直觉的层级数。
//      因此根 "." 的子条目深度为 0（"./x" 被 Join 清成 "x"，分量数不增），
//      而根 "src" 的子条目深度为 1。此处照搬，见 path_components。
//   3. 检查顺序（目录）：深度 → 默认跳过目录 → .gitignore → 产出(可选) → 递归。
//      检查顺序（非目录）：.gitignore → 符号链接 → 常规文件 → glob → 二进制。
//      注意符号链接**不受** glob 过滤（gx 在 glob 之前就 return 了）。
//   4. 默认跳过目录集（.git/.hg/.svn/node_modules/vendor/target/build/.idea/.vscode）
//      对根本身也生效——根目录若叫 "build" 则整个根被跳过。
//   5. .gitignore 多级继承 + 按目录缓存；`.gitignore` 文件自身永不被忽略。
//   6. 二进制判定：前 512 字节含 NUL；打不开/读失败一律按二进制（跳过）。
//   7. 符号链接不跟随（Go WalkDir 语义）；仅 include_symlink 时产出，
//      且 size/mode 取链接自身（lstat）。
//   8. 根路径可以是文件：此时只对该文件走「非目录」分支。
//
// 内存策略（两类分配器，职责分离）：
//   * arena（Dynamic_Arena，backing = cfg.allocator）：一切**字符串字节**——
//     entry.path/name、路径拼接、.gitignore 文件内容。选 arena 而非逐块
//     new/delete 的原因：Odin 的 os.join_path/os.clean_path 内部缓冲区从不
//     单独释放（其 TEMP_ALLOCATOR_GUARD 只换不还，见 core/os/path.odin），
//     按堆分配器逐个调用会稳定泄漏；arena 把这些内部垃圾一并收走，在
//     walk_result_destroy 处批量释放。
//   * cfg.allocator（堆）：控制结构——entries 动态数组、matchers map、
//     matcher 结构体、lstat/read_dir 的 File_Info（显式 file_info_delete）。
//   * .gitignore 的 pattern 字符串**借用** arena 中的文件内容（lib 层约定：
//     content 必须比 matcher 活得久），因此 matcher 只需释放结构体自身。
// ============================================================================

import "base:runtime"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"
import "odd:lib"

// 遍历配置（对齐 gx walker.Config 中被各命令实际使用的字段）。
Walker_Config :: struct {
	paths:            []string, // 根路径列表；为空时按 gx 默认 ["."]
	file_pattern:     string,   // 非空时按 basename glob 过滤（仅普通文件）
	include_dir:      bool,     // 产出目录条目（list -t d/a）
	skip_binary:      bool,     // 跳过二进制文件（find/replace）
	max_depth:        int,      // >0 限制深度；0 = 不限（对齐 gx）
	include_symlink:  bool,     // 产出符号链接（list -t l/a）
	ignore_gitignore: bool,     // true = --all，忽略 .gitignore
	allocator:        runtime.Allocator,
}

// arena 块大小：一次小遍历（几百文件）通常 1-2 块；大仓库按需增长。
WALK_ARENA_BLOCK :: 64 * 1024

// 遍历结果。entries 顺序 = gx filepath.WalkDir 顺序。
// 注意：entries 的 path/name 及内部所有字符串都活在被 destroy 的 arena 里。
Walk_Result :: struct {
	entries:   [dynamic]lib.File_Entry,
	matchers:  map[string]^lib.Gitignore_Matcher, // dir → matcher 缓存（含共享的 parent）
	arena:     mem.Dynamic_Arena,
	allocator: runtime.Allocator,
}

// 遍历状态（递归参数聚合）。
Walk_State :: struct {
	cfg: Walker_Config,
	res: ^Walk_Result,
}

// 字符串分配器：arena（瞬态字符串专用）。
str_alloc :: proc(st: ^Walk_State) -> runtime.Allocator {
	return mem.dynamic_arena_allocator(&st.res.arena)
}

// 遍历入口：顺序处理每个根，收集全部条目。
walk :: proc(cfg: Walker_Config) -> (res: Walk_Result) {
	res.allocator = cfg.allocator
	res.matchers = make(map[string]^lib.Gitignore_Matcher, cfg.allocator)
	mem.dynamic_arena_init(&res.arena, cfg.allocator, cfg.allocator, WALK_ARENA_BLOCK)
	paths := cfg.paths
	if len(paths) == 0 {
		paths = {"."} // gx walker.New：空 paths → ["."]
	}
	for root in paths {
		walk_root(&res, cfg, root)
	}
	return res
}

// 释放 walk 产物：arena（全部字符串）+ 控制结构（堆）。
// matcher 链存在共享（目录无 .gitignore 时缓存的是 parent 对象），按指针去重。
walk_result_destroy :: proc(res: ^Walk_Result) {
	mem.dynamic_arena_destroy(&res.arena)
	delete_dynamic_array(res.entries)
	if res.matchers != nil {
		seen := make(map[^lib.Gitignore_Matcher]bool, res.allocator)
		defer delete(seen)
		for _, m in res.matchers {
			if m == nil {
				continue
			}
			if _, ok := seen[m]; ok {
				continue
			}
			seen[m] = true
			lib.destroy_gitignore_matcher(m, res.allocator)
		}
		delete(res.matchers)
		res.matchers = nil
	}
}

// 单个根：gx 的 WalkDir 先 Lstat，失败则静默跳过（无输出、退出码不受影响）。
walk_root :: proc(res: ^Walk_Result, cfg: Walker_Config, root: string) {
	fi, err := os.lstat(root, cfg.allocator)
	if err != nil {
		return
	}
	defer os.file_info_delete(fi, cfg.allocator)
	st := Walk_State{cfg = cfg, res = res}
	parent, _ := go_dir(root, str_alloc(&st)) // arena：无需单独释放
	root_depth := path_components(root)
	visit(&st, root, filepath.base(root), fi, parent, root_depth)
}

// 访问一个条目。path/name 在递归中传递；parent 是该条目所在目录
// （用于 .gitignore 查询，避免每个文件都做一次 Dir 分配）。
visit :: proc(st: ^Walk_State, path: string, name: string, fi: os.File_Info, parent: string, root_depth: int) {
	cfg := st.cfg
	// ---- 深度限制 ----
	// gx 的 currentDepth = Split(path,"/") 的元素数 - Split(root,"/") 的元素数。
	// 注意它算的是**路径串分量数**而不是树层数：root="." 时 Join 会把 "." 吃掉，
	// 于是 ./deep 变成 "deep"（深度 0）、deep/nest 深度 1——照抄才能与 gx 对齐。
	// 目录超限 → 整棵子树跳过（gx 返回 filepath.SkipDir），文件超限 → 只跳过自己。
	if cfg.max_depth > 0 {
		current_depth := path_components(path) - root_depth
		if current_depth > cfg.max_depth {
			return
		}
	}

	if fi.type == .Directory {
		if lib.is_default_skip_dir(name) {
			return
		}
		if !cfg.ignore_gitignore && is_ignored(st, parent, name, true) {
			return
		}
		if cfg.include_dir {
			emit(st, path, name, fi, /*is_dir*/ true, /*is_symlink*/ false, 0)
		}
		// ---- 递归子条目 ----
		f, oerr := os.open(path, os.O_RDONLY)
		if oerr != nil {
			return // gx：WalkDir 读目录失败 → 跳过该目录内容，兄弟继续
		}
		defer os.close(f)
		infos, rerr := os.read_dir(f, -1, cfg.allocator)
		if rerr != nil {
			return
		}
		defer {
			for i in infos {
				os.file_info_delete(i, cfg.allocator)
			}
			delete(infos, cfg.allocator)
		}
		sort_infos_by_name(infos)
		for cfi in infos {
			cpath, jerr := filepath.join({path, cfi.name}, str_alloc(st))
			if jerr != nil {
				continue
			}
			visit(st, cpath, cfi.name, cfi, path, root_depth)
		}
		return
	}

	// ---- 非目录：gx 顺序 = gitignore → 符号链接 → 常规 → glob → 二进制 ----
	if !cfg.ignore_gitignore && is_ignored(st, parent, name, false) {
		return
	}
	if fi.type == .Symlink {
		if cfg.include_symlink {
			emit(st, path, name, fi, false, true, fi.size)
		}
		return
	}
	if fi.type != .Regular {
		return // 设备/管道/socket 等
	}
	if cfg.file_pattern != "" {
		matched, merr := filepath.match(cfg.file_pattern, name)
		if merr != nil || !matched {
			return
		}
	}
	if cfg.skip_binary && is_binary_file(path) {
		return
	}
	emit(st, path, name, fi, false, false, fi.size)
}

// 产出一个条目：path/name 克隆进 arena（随 walk_result_destroy 释放）。
emit :: proc(st: ^Walk_State, path: string, name: string, fi: os.File_Info, is_dir, is_symlink: bool, size: i64) {
	alloc := str_alloc(st)
	path_clone, perr := strings.clone(path, alloc)
	if perr != nil {
		return
	}
	name_clone, nerr := strings.clone(name, alloc)
	if nerr != nil {
		return
	}
	append(&st.res.entries, lib.File_Entry{
		path          = path_clone,
		name          = name_clone,
		is_dir        = is_dir,
		is_symlink    = is_symlink,
		size          = size,
		mod_time      = fi.modification_time,
		creation_time = fi.creation_time,
		perm          = fi.mode,
	})
}

// .gitignore 查询（gx Walker.isIgnored）：.gitignore 自身永不忽略；
// 加载（含缓存）所在目录的 matcher 后按名字匹配。
is_ignored :: proc(st: ^Walk_State, dir: string, name: string, is_dir: bool) -> bool {
	if name == ".gitignore" {
		return false
	}
	m := load_gitignore(st, dir)
	if m == nil {
		return false
	}
	return lib.match(m, name, is_dir)
}

// 加载目录的 matcher（gx Walker.loadGitignore）：按目录缓存；
// 无 .gitignore 时缓存的就是 parent 对象（因此缓存值可能共享，释放需去重）。
// 文件内容读进 arena（pattern 字符串借用它，见 lib/gitignore.odin 约定）。
load_gitignore :: proc(st: ^Walk_State, dir: string) -> ^lib.Gitignore_Matcher {
	if m, ok := st.res.matchers[dir]; ok {
		return m
	}
	parent_dir, ok := go_dir(dir, str_alloc(st))
	parent: ^lib.Gitignore_Matcher
	if ok && parent_dir != dir {
		parent = load_gitignore(st, parent_dir)
	}
	gi_path, jerr := filepath.join({dir, ".gitignore"}, str_alloc(st))
	m := parent
	if jerr == nil {
		if content, cok := os.read_entire_file(gi_path, str_alloc(st)); cok == nil {
			// 结构体走堆；pattern 字符串借用 arena 中的 content
			m = lib.new_gitignore_matcher(string(content), parent, st.cfg.allocator)
		}
	}
	st.res.matchers[dir] = m
	return m
}

// 二进制判定（gx isBinaryFile）：前 512 字节含 NUL 即二进制；
// 打开失败/读取失败按二进制处理（等价于跳过该文件）。
is_binary_file :: proc(path: string) -> bool {
	f, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return true
	}
	defer os.close(f)
	buf: [512]u8
	n, rerr := os.read(f, buf[:])
	if rerr != nil && rerr != io.Error.EOF {
		return true
	}
	for i in 0..<n {
		if buf[i] == 0 {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// 路径工具（对齐 Go path/filepath 的语义差异）
// ---------------------------------------------------------------------------

// Go filepath.Dir 语义：去掉最后一段；无分隔符 → "."；"/" → "/"。
// Odin 的 filepath.dir 对 "a"/"." 返回 ""（Go 返回 "."），而 gitignore
// 父链递归以 Dir(dir) == dir 为终止条件，必须照搬 Go 行为。
// 结果字符串由调用方传入的分配器管理（walker 传 arena，无需单独释放）。
go_dir :: proc(path: string, allocator := context.allocator) -> (dir: string, ok: bool) {
	prefix: string
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		prefix = path[:i + 1]
	}
	cleaned, err := filepath.clean(prefix, allocator)
	if err != nil {
		return "", false
	}
	return cleaned, true
}

// gx 深度公式的分量计数：strings.Split(path, "/") 的元素个数。
// "" → 1，"a" → 1，"a/b" → 2，"/" → 2，"//" → 3。
path_components :: proc "contextless" (path: string) -> int {
	n := 1
	for i in 0..<len(path) {
		if path[i] == '/' {
			n += 1
		}
	}
	return n
}

// 字节序字典比较（Go 的 string "<" 语义；Odin 无字符串关系运算符）。
name_less :: proc "contextless" (a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0..<n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

// 把 read_dir 结果按名字排序（Go filepath.WalkDir 的字典序保证）。
// core:sort 的 Interface 用 rawptr 携带集合；这里传「切片头」的指针
// （必须是 ^[]T，不能是 &T[0]——后者会被当成切片头解引用出垃圾长度）。
sort_infos_by_name :: proc(infos: []os.File_Info) {
	if len(infos) < 2 {
		return
	}
	local := infos // 参数不可取地址，复制一份切片头（共享同一 backing array）
	it := sort.Interface{
		len        = _fi_len,
		less       = _fi_less,
		swap       = _fi_swap,
		collection = rawptr(&local),
	}
	sort.sort(it)
}

_fi_len :: proc(it: sort.Interface) -> int {
	s := cast(^[]os.File_Info)it.collection
	return len(s^)
}

_fi_less :: proc(it: sort.Interface, i, j: int) -> bool {
	s := cast(^[]os.File_Info)it.collection
	return name_less(s[i].name, s[j].name)
}

_fi_swap :: proc(it: sort.Interface, i, j: int) {
	s := cast(^[]os.File_Info)it.collection
	s[i], s[j] = s[j], s[i]
}
