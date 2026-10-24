package engine

// ============================================================================
// processor.odin — 遍历 → 工作池 → 回调 流水线（复刻 gx processor.Engine）
//
// 职责：把 walker 产出的条目分发给 N 个工作执行体，逐条调用命令方的
//       handle_file 回调。
//
// 与 gx 的差异（Odin 约束所致，行为等价）：
//   * gx 用 goroutine + channel 流式对接「walk 边遍历边处理」；这里先把
//     遍历结果收集成数组（walk 本身是单线程顺序的，顺序与 gx 一致），
//     再用线程池消费。workers=1 时退化为纯顺序执行，输出顺序与 gx 逐字节相同。
//   * gx 的 FileProcessor 接口（ProcessFile + HandleResult 两个方法）在这里
//     合并为一个 handle_file 回调：workers=1 顺序执行时，二者的可观察行为
//     完全一致（一个文件的全部结果连续产出）。
//   * Odin 闭包不捕获外层变量，回调用 C 风格 ctx: rawptr + proc 指针传递。
//
// 并发安全约定（与 xrep engine/worker.odin 同款，实测教训）：
//   线程入口第一步必须 `context = runtime.default_context()`。Odin 新建线程
//   会复制创建者的 context；`odin test` 下创建者是测试运行器，其分配器是
//   mem.Tracking_Allocator——内部无锁 map，多线程并发分配会写坏数据结构，
//   表现为偶发 SIGBUS。归一化后线程只用堆分配器，与创建者无关。
//
// 条目抢占：next 为原子自增索引，worker 抢到即处理；空转线程在越界时退出。
// ============================================================================

import "base:runtime"
import "core:os"
import "core:sync"
import "core:thread"
import "odd:lib"

// 每文件处理回调。ctx 由调用方自定义（通常指向命令的状态结构体）。
File_Handler :: struct {
	ctx:        rawptr,
	handle_file: proc(ctx: rawptr, entry: ^lib.File_Entry),
}

// 驱动流水线。workers <= 0 → 逻辑核心数（-j 0）；1 → 顺序执行（默认）。
// 阻塞直到全部条目处理完毕。
run :: proc(entries: []lib.File_Entry, handler: File_Handler, workers: int) {
	n := len(entries)
	if n == 0 || handler.handle_file == nil {
		return
	}
	w := workers
	if w <= 0 {
		w = os.get_processor_core_count() // 对齐 Go runtime.NumCPU
	}
	if w > n {
		w = n // 不创建空转线程
	}
	if w <= 1 {
		for i in 0..<n {
			handler.handle_file(handler.ctx, &entries[i])
		}
		return
	}

	pool := Pool{
		entries = entries,
		handler = handler,
	}
	threads := make([]^thread.Thread, w, context.allocator)
	defer {
		for t in threads {
			thread.destroy(t)
		}
		delete(threads, context.allocator)
	}
	for i in 0..<w {
		threads[i] = thread.create_and_start_with_data(&pool, pool_worker)
	}
	for t in threads {
		thread.join(t)
	}
}

// 共享状态：条目数组（只读）+ 回调 + 原子抢占游标。
Pool :: struct {
	entries: []lib.File_Entry,
	handler: File_Handler,
	next:    int,
}

// 工作线程主体：抢索引 → 处理 → 越界退出。
// 注意：sync.atomic_add 是 fetch-and-add 语义——返回「加之前」的旧值
// （已在 dev-2026-10 实证：连续两次调用返回 0、1）。因此返回值即本次抢占的
// 索引，不能再减 1（曾因误按「返回新值」处理导致首索引 -1 越界崩溃）。
pool_worker :: proc(data: rawptr) {
	// 先归一化上下文（原因见文件头"并发安全约定"）。
	context = runtime.default_context()
	pool := cast(^Pool)data
	for {
		i := sync.atomic_add(&pool.next, 1)
		if i >= len(pool.entries) {
			break
		}
		pool.handler.handle_file(pool.handler.ctx, &pool.entries[i])
	}
}
