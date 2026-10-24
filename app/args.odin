package app

// ============================================================================
// args.odin — 命令行参数解析（逐条复刻 gx args 包）
//
// 对齐 gx args.go 的三个入口：
//   parse_common  完整解析：选项（短/长）→ 位置参（pattern → replace → paths）
//   parse_simple  智能模式：无选项且 1/2 个位置参时走快捷分支，否则回落
//                  parse_common
//   format_options  用法文本中的选项列表
//
// 与 gx 的差异（Odin 约束所致，行为等价）：
//   * Go 闭包捕获外层 config；Odin 闭包不捕获 → handler 用 C 风格
//     ctx: rawptr（指向命令自己的 Config）。
//   * **约定：各命令 Config 必须把 Common_Config 作为第一个字段**，
//     这样 rawptr(&c.common_config) == rawptr(&c)，handler 里
//     cast(^Xxx_Config)ctx 即可读写全部字段（含公共字段）。
//   * Go 的 map[string]*Option 查找表在这里是小数组线性扫描
//     （选项表 ≤12 项，语义一致：短名/长名精确匹配）。
//   * -j/-L 的数值解析复刻 fmt.Sscanf("%d")：取前导整数，失败保持原值，
//     handler 恒返回 true（见 parse_int_prefix）。
//
// 位置参分配规则（gx ParseCommon 原样）：
//   第一个位置参 → pattern；第二个 → replace（replace_set = true）；
//   其余 → paths。全部走完仍无 paths → 默认 ["."]。
//   未知选项（optionMap 未命中的 "-xxx"）按**位置参**处理。
// ============================================================================

import "core:fmt"
import "core:os"
import "core:strings"

// 通用配置：find/replace/rename/cut/trans/script 共享的位置参数与公共选项。
// 对应 gx args.CommonConfig。
Common_Config :: struct {
	pattern:          string,       // 搜索模式（正则或字面量）
	replace:          string,       // 替换串
	replace_set:      bool,         // 是否提供了替换串
	paths:            [dynamic]string, // 目录/文件列表（context.allocator）
	ignore_case:      bool,         // -i
	file_pattern:     string,       // -g
	dry_run:          bool,         // 默认 true；-x 置 false
	ignore_gitignore: bool,         // -A / --all
}

// 选项处理器：value = 选项值（flag 类为空串）；ctx = 命令 Config 指针。
// 返回 false 表示取值非法（调用方终止解析）。
Option_Handler :: proc(value: string, ctx: rawptr) -> bool

// 命令行选项（flag 或带值选项）。对应 gx args.Option。
Option :: struct {
	short:      string, // 短名（如 "-i"）；可空
	long:       string, // 长名（如 "--ignore-case"）；可空
	has_value:  bool,   // 是否需要取值
	value_name: string, // 用法文本中的值占位名
	help:       string, // 帮助文本
	handler:    Option_Handler,
}

// 在选项表中按短名/长名精确查找。返回表内元素指针（options 须比调用活得久）。
// 空名字不参与匹配——gx 构建 optionMap 时跳过 Short/Long 为空的项，
// 否则仅长名的选项会被空串位置参（""）误命中。
find_option :: proc(options: []Option, name: string) -> ^Option {
	if name == "" {
		return nil
	}
	for &opt in options {
		if opt.short == name || opt.long == name {
			return &opt
		}
	}
	return nil
}

// parse_common — 完整解析（复刻 gx ParseCommon）。
// print_usage 在 -h/--help 或缺值时报错后调用；返回 false 时调用方应退出。
// ctx 约定：handler 收到的 rawptr 就是 config 本身的地址。
parse_common :: proc(args: []string, config: ^Common_Config, options: []Option, print_usage: proc()) -> bool {
	for i := 0; i < len(args); i += 1 {
		arg := args[i]

		if opt := find_option(options, arg); opt != nil {
			if opt.has_value {
				if i + 1 >= len(args) {
					fmt.fprintf(os.stderr, "Error: %s requires a value\n", arg)
					return false
				}
				if !opt.handler(args[i + 1], rawptr(config)) {
					return false
				}
				i += 1 // 跳过已消费的值
			} else {
				if !opt.handler("", rawptr(config)) {
					return false
				}
			}
		} else if arg == "-h" || arg == "--help" {
			print_usage()
			return false
		} else {
			// 位置参（含未注册的 "-xxx"）：pattern → replace → paths
			if config.pattern == "" {
				config.pattern = arg
			} else if !config.replace_set {
				config.replace = arg
				config.replace_set = true
			} else {
				append(&config.paths, arg)
			}
		}
	}

	// 一个路径都没给 → 默认当前目录（gx 同款）
	if len(config.paths) == 0 {
		append(&config.paths, ".")
	}
	return true
}

// parse_simple — 智能模式（复刻 gx ParseSimple）。
//
// 分支：
//   0 参              → 用法，false
//   含 -h/--help      → 用法，false（先于一切检查）
//   任一参是已注册选项 → parse_common
//   1 参              → pattern，paths = ["."]
//   2 参              → pattern=args[0]，paths=[args[1]]（第二参是路径，
//                        与 find 语义一致；要替换串用 -r 或 3 个位置参）
//   其余              → parse_common
parse_simple :: proc(args: []string, config: ^Common_Config, options: []Option, print_usage: proc()) -> bool {
	size := len(args)
	if size == 0 {
		print_usage()
		return false
	}

	// 帮助flag 优先（gx：slices.Contains 全量扫描）
	for arg in args {
		if arg == "-h" || arg == "--help" {
			print_usage()
			return false
		}
	}

	// 只要出现任一已注册选项，就走完整解析
	for arg in args {
		if find_option(options, arg) != nil {
			return parse_common(args, config, options, print_usage)
		}
	}

	if size == 1 {
		config.pattern = args[0]
		append(&config.paths, ".")
		return true
	}

	if size == 2 {
		// 两个位置参：PATTERN PATH（find 语义）
		config.pattern = args[0]
		append(&config.paths, args[1])
		return true
	}

	return parse_common(args, config, options, print_usage)
}

// format_options — 生成用法文本中的选项列表（复刻 gx FormatOptions）。
// 产出四种对齐形态（短+长 / 仅短 / 仅长，各分带值与不带值）：
//
//	-i, --ignore-case    Case insensitive search
//	-g, --glob <PATTERN>    File glob pattern
//
// 返回堆字符串（context.allocator），调用方负责 delete。
// 注意：strings.to_string 返回的是 builder 缓冲区的视图（所有权转移），
// 因此这里绝不能 builder_destroy（那会释放返回串的底层内存）。
format_options :: proc(options: []Option) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	for &opt in options {
		// 四种对齐形态（gx FormatOptions 原样）：短+长 / 仅短 / 仅长，各分带值与不带值
		if opt.short != "" && opt.long != "" {
			if opt.has_value {
				fmt.sbprintf(&b, "  %s, %s <%s>    %s\n", opt.short, opt.long, opt.value_name, opt.help)
			} else {
				fmt.sbprintf(&b, "  %s, %s    %s\n", opt.short, opt.long, opt.help)
			}
		} else if opt.short != "" {
			if opt.has_value {
				fmt.sbprintf(&b, "  %s <%s>    %s\n", opt.short, opt.value_name, opt.help)
			} else {
				fmt.sbprintf(&b, "  %s    %s\n", opt.short, opt.help)
			}
		} else if opt.long != "" {
			if opt.has_value {
				fmt.sbprintf(&b, "  %s <%s>    %s\n", opt.long, opt.value_name, opt.help)
			} else {
				fmt.sbprintf(&b, "  %s    %s\n", opt.long, opt.help)
			}
		}
	}
	return strings.to_string(b)
}

// parse_int_prefix — 复刻 fmt.Sscanf(v, "%d") 的取值语义：从串首解析
// （带符号）十进制整数，遇非数字即停；失败返回 false、*out 保持原值。
// 用于 -j/-L 等"垃圾输入不报错、保持默认"的选项。
parse_int_prefix :: proc(s: string, out: ^int) -> bool {
	i := 0
	neg := false
	if i < len(s) && (s[i] == '+' || s[i] == '-') {
		neg = s[i] == '-'
		i += 1
	}
	start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i += 1
	}
	if i == start {
		return false // 没有数字位
	}
	n: int
	for d := start; d < i; d += 1 {
		n = n * 10 + int(s[d] - '0')
	}
	if neg {
		n = -n
	}
	out^ = n
	return true
}
