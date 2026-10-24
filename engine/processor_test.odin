package engine

// ============================================================================
// processor_test.odin — 工作池测试
//
// 覆盖：
//   * workers=1：顺序执行，产出顺序与条目顺序一致
//   * workers=0（全部核心）/ workers>条目数：不崩、不重不漏
//   * 空条目：零回调
//   * 多线程下回调的并发安全（mutex 保护的结果收集）
// ============================================================================

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "odd:lib"

// 测试回调的共享状态：结果收集 + 互斥锁 + 调用计数。
// 注意：回调运行在 worker 线程（context 已归一化为堆分配器），但 results
// 动态数组由主线程用追踪分配器创建——append 用数组自身的分配器，故必须
// 持锁串行化，与 xrep 的并发约定一致。
Collect_Ctx :: struct {
	mu:      sync.Mutex,
	results: [dynamic]string,
	calls:   int,
}

collect_handle :: proc(ctx: rawptr, entry: ^lib.File_Entry) {
	c := cast(^Collect_Ctx)ctx
	sync.mutex_lock(&c.mu)
	defer sync.mutex_unlock(&c.mu)
	c.calls += 1
	append(&c.results, entry.path)
}

// 构造 N 个伪条目（不需要真实文件，processor 只转发指针）。
// allocator 用命名实参传给 aprintf（位置实参会被 ..any 吞掉，见 walker_test 注释）。
fake_entries :: proc(n: int) -> [dynamic]lib.File_Entry {
	out: [dynamic]lib.File_Entry
	for i in 0..<n {
		append(&out, lib.File_Entry{path = fmt.aprintf("f%d", i, allocator = context.temp_allocator)})
	}
	return out
}

@(test)
test_run_sequential :: proc(t: ^testing.T) {
	entries := fake_entries(5)
	defer delete_dynamic_array(entries)
	ctx: Collect_Ctx
	defer delete(ctx.results)
	run(entries[:], File_Handler{ctx = &ctx, handle_file = collect_handle}, 1)
	testing.expectf(t, ctx.calls == 5, "应处理 5 条, got %d", ctx.calls)
	testing.expectf(t, len(ctx.results) == 5, "应收集 5 条, got %d", len(ctx.results))
	for i in 0..<len(ctx.results) {
		want := fmt.aprintf("f%d", i, allocator = context.temp_allocator)
		testing.expectf(t, ctx.results[i] == want, "第 %d 条: got %q want %q", i, ctx.results[i], want)
	}
}

@(test)
test_run_parallel_all_cores :: proc(t: ^testing.T) {
	entries := fake_entries(50)
	defer delete_dynamic_array(entries)
	ctx: Collect_Ctx
	defer delete(ctx.results)
	// workers=0 → 全部逻辑核心；条目足够多，务必每个都被处理且仅一次
	run(entries[:], File_Handler{ctx = &ctx, handle_file = collect_handle}, 0)
	testing.expectf(t, ctx.calls == 50, "应处理 50 条, got %d", ctx.calls)
	testing.expectf(t, len(ctx.results) == 50, "应收集 50 条, got %d", len(ctx.results))
	// 集合校验：不重不漏（顺序不保证）
	seen := make(map[string]int, context.temp_allocator)
	for p in ctx.results {
		seen[p] += 1
	}
	testing.expectf(t, len(seen) == 50, "应有 50 个不同路径, got %d", len(seen))
	for i in 0..<50 {
		k := fmt.aprintf("f%d", i, allocator = context.temp_allocator)
		testing.expectf(t, seen[k] == 1, "%q 应恰好出现 1 次, got %d", k, seen[k])
	}
}

@(test)
test_run_workers_capped :: proc(t: ^testing.T) {
	entries := fake_entries(3)
	defer delete_dynamic_array(entries)
	ctx: Collect_Ctx
	defer delete(ctx.results)
	// workers 远大于条目数：线程数应收敛到条目数，不崩不漏
	run(entries[:], File_Handler{ctx = &ctx, handle_file = collect_handle}, 100)
	testing.expectf(t, ctx.calls == 3, "应处理 3 条, got %d", ctx.calls)
}

@(test)
test_run_empty :: proc(t: ^testing.T) {
	ctx: Collect_Ctx
	defer delete(ctx.results)
	// 空条目：零回调（workers=0 时也不能崩）
	run(nil, File_Handler{ctx = &ctx, handle_file = collect_handle}, 0)
	run(nil, File_Handler{ctx = &ctx, handle_file = collect_handle}, 1)
	testing.expectf(t, ctx.calls == 0, "空条目应零回调, got %d", ctx.calls)
}

@(test)
test_run_nil_handler :: proc(t: ^testing.T) {
	entries := fake_entries(2)
	defer delete_dynamic_array(entries)
	// 句柄为 nil：直接返回，不崩
	run(entries[:], File_Handler{ctx = nil, handle_file = nil}, 1)
	run(entries[:], File_Handler{ctx = nil, handle_file = nil}, 4)
}
