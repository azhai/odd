package lib

// ============================================================================
// base.odin — lib 包基础层（依赖根）
//
// 职责：运行期常量、跨模块共享的数据结构（遍历产物 / 命中结果 / 匹配区间）、
//       最基础的字节工具。不引用任何本工程包，被 engine / app 共同使用。
//
// 数据集中放在 lib（对齐 xrep ADR 0007 的组织方式）：所有跨模块流转的类型
// 都在这里，各包只保留行为代码，依赖图最底层只有一个包。
// ============================================================================

import "core:os"
import "core:time"

// 版本号：由 --version 输出。对外行为变更时递增。
ODD_VERSION :: "0.1.0"

// 提交号：与 gx 的 `Version()` 同形 —— `%s (commit: %s)`。
// 构建时可用 -define:ODD_COMMIT=xxx 覆盖，默认取仓库当前短 hash（见 build.sh），
// 未注入时退化为 "dev"（不阻断构建，也不假装知道）。
ODD_COMMIT :: #config(ODD_COMMIT, "dev")

// ANSI 转义序列。gx 全程恒彩色（无 TTY 探测），仅 --no-color 关闭；
// 各命令的用法与 gx 逐字对应：
//   find/replace 命中高亮 红     dry-run 黄    替换成功 绿
//   写入失败 红                  新行预览 青    rename 预览同色系
COLOR_RED     :: "\x1b[31m"
COLOR_YELLOW  :: "\x1b[33m"
COLOR_GREEN   :: "\x1b[32m"
COLOR_CYAN    :: "\x1b[36m"
COLOR_RESET   :: "\x1b[0m"

// gx walker 默认跳过的目录名（版本控制 / 依赖 / IDE 产物）。
// 用 proc 而非全局 map：不可变、零分配、可被单测直接断言。
is_default_skip_dir :: proc(name: string) -> bool {
	switch name {
	case ".git", ".hg", ".svn", "node_modules", "vendor", "target", "build", ".idea", ".vscode":
		return true
	}
	return false
}

// 字符串 → []u8（零拷贝视图，与入参共享底层内存，调用方不拥有所有权）。
s2b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// ---------------------------------------------------------------------------
// 跨模块共享的数据结构
// ---------------------------------------------------------------------------

// 遍历产物：walker 产出的文件 / 目录 / 符号链接条目。
// list 命令直接消费全部字段；find/replace/rename 只用 path。
// 注意：path/name 由 walker 克隆到堆上，随 walk_result_destroy 一并释放。
File_Entry :: struct {
	path:          string, // 完整路径（相对/绝对取决于输入）
	name:          string, // basename
	is_dir:        bool,
	is_symlink:    bool,
	size:          i64, // 目录为 0
	mod_time:      time.Time,
	creation_time: time.Time, // 跨平台"创建/变更时间"，语义见 README 已知行为
	perm:          os.Permissions, // 权限位（setuid/sticky 被 Odin API 掩码，见 README）
}

// 一行命中：路径、1-based 行号、行内容（不含换行）、行内匹配区间 [start, end)。
// 与 gx processor.Result 对应。
Line_Match :: struct {
	path:     string,
	line_num: int,
	line:     string,
	matches:  [][2]int,
}

// 大小比较运算符（sizeexpr / timeexpr 共用）。
Operator :: enum {
	LT, // <
	LE, // <=
	GT, // >
	GE, // >=
	EQ, // 无前缀，相等
}
