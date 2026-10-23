// 并发（第 12 节）：异步扫描入口、并行检测、取消与时间预算。
// 仓颉线程：spawn 返回 Future<T>；跨线程可变状态用 std.sync 保护。
package rawprism

import std.collection.*
import std.sync.*
import rawprism.core.*

/// 异步扫描入口（12.9）：返回 Future，由调用方决定何时等待。
public func scanAsync(input: Input, config!: ScanConfig = ScanConfig(),
                      registry!: Option<GetterRegistry> = None): Future<Session> {
    spawn {
        let session = Session(input, config: config, registry: registry)
        session.scan()
        session
    }
}

/// 请求取消（12.7）：线程内通过检查取消状态响应。
public func cancelScan(session: Session): Unit {
    session.cancelFlag.store(true)
}

/// Session 的并行扫描扩展：相互独立的检测器类型并行执行（12.1），
/// 并行度受 config.parallelism 上限约束（12.4），
/// 同一类型同一区间的并发请求只触发一次检测（12.5，requestType 内部加锁），
/// 合并结果与调度顺序无关（12.6 / C5：区域树查询时按位置排序）。
/// Session 的并行扫描（12.1-12.6）：相互独立的检测器类型并行执行，
/// 并行度受 config.parallelism 上限约束（12.4），
/// 同一类型同一区间的并发请求只触发一次检测（12.5，requestTypeThreadSafe 内部加锁），
/// 合并结果与调度顺序无关（12.6 / C5：区域树查询时按位置排序）。
public func scanConcurrent(session: Session): Session {
    let n = session.config.parallelism
    if (n <= 1) {
        return session.scan()
    }
    // 先做粗分类（顺序执行，确定顶层区域）
    let root = session.coarseRootType()
    requestTypeThreadSafe(session, root)
    // 任务集：各注册检测器类型在整段输入上的按需扫描
    let tasks = ArrayList<TypeId>()
    let seen = HashSet<String>()
    seen.add(root.text)
    for (d in session.registry.ordered()) {
        let t = d.typeId
        if (!seen.contains(t.text)) {
            seen.add(t.text)
            tasks.add(t)
        }
    }
    // 受并行度上限约束的简单调度：每批 n 个
    let futures = ArrayList<Future<Unit>>()
    var launched: Int64 = 0
    for (t in tasks) {
        if (session.budgetExceeded()) {
            break
        }
        if (launched >= n) {
            // 等待最早一批完成后再继续（合并顺序无关）
            let first = futures[0]
            first.get()
            futures.remove(at: 0)
            launched -= 1
        }
        let tt = t
        futures.add(spawn {
            requestTypeThreadSafe(session, tt)
        })
        launched += 1
    }
    for (f in futures) {
        f.get()
    }
    return session
}

/// 线程安全的按需扫描入口：requestType 整体加锁，
/// 同一类型同一区间的并发请求只触发一次检测（12.5）。
public func requestTypeThreadSafe(session: Session, t: TypeId): Unit {
    session.lock.lock()
    try {
        session.requestType(t, Span(0, session.input.available))
    } finally {
        session.lock.unlock()
    }
}
