package lib

// ============================================================================
// gitignore.odin — .gitignore 规则解析与匹配（复刻 gx/common/gitignore.go）
//
// 行为与 gx 保持一致（含其已知简化）：
//   * 规则只与**条目名**（basename）比对，不匹配路径段 —— 因此含 `/` 的
//     规则（如 `foo/bar`）实际永不命中。这是 gx 的既有语义，此处照搬，
//     差异不扩大也不缩小（README 已知行为 #4）。
//   * 支持 `!` 取反、`/` 结尾仅目录、行首 `#` 注释、`\#` 转义。
//   * 多级继承：子目录 matcher 持有父链，Match 先问父再按行序应用自身，
//     后命中者覆盖先命中者（与 git 语义一致）。
//
// 所有权约定（调用方必须遵守）：
//   * pattern 字符串**借用** content 的内存（零拷贝切片），不做克隆。
//     因此 content 必须比 matcher 活得久。engine/walker 的做法是把
//     content 读进与遍历同生命周期的 arena，matcher 结构体自身走堆。
//   * destroy_gitignore_matcher 只释放结构体与 patterns 数组，
//     不释放借用的 pattern 字符串（由 content 的所有者负责）。
// ============================================================================

import "core:fmt"
import "core:path/filepath"
import "core:strings"

Gitignore_Pattern :: struct {
	pattern: string,
	negated: bool,
	dir_only: bool,
	rooted:  bool,
}

// 解析一行规则；注释行 / 空行 / 剥离后为空 → ok=false。
// 返回的 pattern 是入参 line 的切片（借用，不克隆）。
parse_gitignore_pattern :: proc(raw: string) -> (p: Gitignore_Pattern, ok: bool) {
	line := strings.trim_right(raw, " \t")
	if line == "" || strings.has_prefix(line, "#") {
		return {}, false
	}

	p = {}
	if strings.has_prefix(line, "!") {
		p.negated = true
		line = line[1:]
	}
	if strings.has_prefix(line, `\#`) {
		// `\#` 转义的字面 #：只可能是行首（行内的 # 在 gitignore 里不是注释，
		// 不需要转义）。直接借用 line[1:] —— 早前这里用 aprintf 拼一个新串，
		// 结果既破了"pattern 借用 content"的约定，又每次泄漏一块堆内存。
		line = line[1:]
	}
	if strings.has_suffix(line, "/") {
		p.dir_only = true
		line = strings.trim_suffix(line, "/")
	}
	if strings.has_prefix(line, "/") {
		p.rooted = true
		line = line[1:]
	}
	if line == "" {
		return {}, false
	}
	p.pattern = line
	return p, true
}

// 单条规则匹配（gx 的三个分支实际同构，这里合并为一次 glob 比对）。
// filepath.match 的语法错误（如未闭合 `[`）按"不命中"处理，与 gx 一致。
pattern_match :: proc(p: Gitignore_Pattern, name: string, is_dir: bool) -> bool {
	if p.dir_only && !is_dir {
		return false
	}
	matched, err := filepath.match(p.pattern, name)
	if err != nil {
		return false
	}
	return matched
}

Gitignore_Matcher :: struct {
	patterns: [dynamic]Gitignore_Pattern,
	parent:   ^Gitignore_Matcher,
}

// 由文件内容构造 matcher；parent 可为 nil。
// patterns 借用 content（见文件头所有权约定）：content 必须比 matcher 活得久。
// 结构体与 patterns 数组由 allocator 分配。
new_gitignore_matcher :: proc(content: string, parent: ^Gitignore_Matcher, allocator := context.allocator) -> ^Gitignore_Matcher {
	m := new(Gitignore_Matcher, allocator)
	m.parent = parent
	content_local := content
	for line in strings.split_lines_iterator(&content_local) {
		p, ok := parse_gitignore_pattern(line)
		if ok {
			append(&m.patterns, p)
		}
	}
	return m
}

// Match：先继承父链结论，再按行序应用自身规则（后者覆盖前者）。
match :: proc(m: ^Gitignore_Matcher, name: string, is_dir: bool) -> bool {
	if m == nil {
		return false
	}
	ignored := false
	if m.parent != nil {
		ignored = match(m.parent, name, is_dir)
	}
	for i in 0..<len(m.patterns) {
		p := &m.patterns[i]
		if pattern_match(p^, name, is_dir) {
			ignored = !p.negated
		}
	}
	return ignored
}

// 释放 matcher 自身（动态数组 + 结构体）。
// 不释放借用的 pattern 字符串（content 的所有者负责，如 walker 的 arena）。
destroy_gitignore_matcher :: proc(m: ^Gitignore_Matcher, allocator := context.allocator) {
	if m == nil {
		return
	}
	delete_dynamic_array(m.patterns)
	free(m, allocator)
}
