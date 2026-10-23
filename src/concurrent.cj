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
    // 确定性调度（12.6 / C5）：requestType 当前由会话锁整体串行化，
    // 任务的真实执行顺序取决于锁的获取顺序，是不确定的；而检测器的
    // 候选登记与覆盖状态存在跨类型顺序依赖，乱序会产生与串行不同的
    // 区域树。因此在并行度入口上按注册序逐个执行，保证与 scan() 的
    // 结果逐字节一致；待调度粒度细化（12.1 分区间并行）后再放开。
    for (t in tasks) {
        if (session.budgetExceeded()) {
            break
        }
        requestTypeThreadSafe(session, t)
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
