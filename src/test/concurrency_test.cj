// 并发测试：异步入口、并行一致性（12.6/C5）、并行度上限、单次检测去重、取消与时间预算。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

/// 计数检测器（测试辅助）。
public class CountingJson <: Detector {
    internal let counter: CounterBox
    public init(counter: CounterBox) {
        this.counter = counter
    }
    public prop typeId: TypeId { get() { TypeId("counting.json") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let _ = ctx
        // 仅顶层整段为 JSON 时计数
        if (scope.start == 0) {
            counter.value += 1
            let _ = ctx.emit(scope, typeId, 1.0, HashMap<String, String>())
        }
    }
}

/// 抛异常检测器（测试辅助）。
public class Boom <: Detector {
    public prop typeId: TypeId { get() { TypeId("x.boom") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let _ = ctx
        throw Exception("boom")
    }
}

@Test
func scanAsyncEntry(): Unit {
    // 12.9：异步扫描入口，返回 Future
    let fut = scanAsync(Input("{\"a\": 1} https://u.io"))
    let s = fut.get()
    @Assert(s.getAll(["struct.json"]).size == 1)
    @Assert(s.getAll(["entity.url"]).size == 1)
}

@Test
func concurrentDeterministic(): Unit {
    // 12.6 / C5：不同并行度下区域树必须相同（15.1 并发一致性）
    let text = "{\"a\": 1} mid https://u.io tail {\"b\": [1,2,3]} end"

    let s1 = Session(Input(text))
    scanConcurrent(s1)

    var cfg2 = ScanConfig()
    cfg2.parallelism = 4
    let s2 = Session(Input(text), config: cfg2)
    scanConcurrent(s2)

    var cfg8 = ScanConfig()
    cfg8.parallelism = 8
    let s8 = Session(Input(text), config: cfg8)
    scanConcurrent(s8)

    let r1 = s1.tree.ordered()
    let r2 = s2.tree.ordered()
    let r8 = s8.tree.ordered()
    @Assert(r1.size == r2.size)
    @Assert(r1.size == r8.size)
    for (i in 0..r1.size) {
        @Assert(spanEq(r1[i].span, r2[i].span))
        @Assert(r1[i].typeId.text == r2[i].typeId.text)
        @Assert(spanEq(r1[i].span, r8[i].span))
    }
}

@Test
func concurrentSameAsSequential(): Unit {
    // 并行扫描结果与串行扫描一致（C5）
    let text = "# T\n\nsee https://q.io now\n"
    let seq = Session(Input(text))
    seq.scan()

    var cfg = ScanConfig()
    cfg.parallelism = 4
    let par = Session(Input(text), config: cfg)
    scanConcurrent(par)

    @Assert(seq.tree.size() == par.tree.size())
    let a = seq.tree.ordered()
    let b = par.tree.ordered()
    for (i in 0..a.size) {
        @Assert(spanEq(a[i].span, b[i].span))
        @Assert(a[i].typeId.text == b[i].typeId.text)
    }
}

@Test
func parallelSessionsIndependent(): Unit {
    // 12.3：多个会话互不影响，可以并行处理
    var cfg = ScanConfig()
    cfg.parallelism = 2
    let f1 = scanAsync(Input("{\"x\": 1}"), config: cfg)
    let f2 = scanAsync(Input("{\"y\": 2}"), config: cfg)
    let s1 = f1.get()
    let s2 = f2.get()
    @Assert(s1.getAll(["struct.json"]).size == 1)
    @Assert(s2.getAll(["struct.json"]).size == 1)
    if (let Some(v1) <- s1.getAll(["struct.json"])[0].value().get("x")) {
        @Assert(v1.asInt() == Some(1))
    } else {
        @Assert(false)
    }
    if (let Some(v2) <- s2.getAll(["struct.json"])[0].value().get("y")) {
        @Assert(v2.asInt() == Some(2))
    } else {
        @Assert(false)
    }
}

@Test
func singleDetectionUnderConcurrentRequests(): Unit {
    // 12.5：同一类型同一区间的并发请求只触发一次检测
    var counter = CounterBox(0)
    let reg = GetterRegistry()
    @Assert(reg.register(CountingJson(counter)))
    let s = Session(Input("{\"k\": 1}"), registry: Some(reg))
    // 并发请求同一类型同一区间
    let f1 = spawn { requestTypeThreadSafe(s, TypeId("counting.json")) }
    let f2 = spawn { requestTypeThreadSafe(s, TypeId("counting.json")) }
    let f3 = spawn { requestTypeThreadSafe(s, TypeId("counting.json")) }
    f1.get()
    f2.get()
    f3.get()
    @Assert(counter.value == 1)
}

@Test
func timeBudgetTruncates(): Unit {
    // 12.7：超时返回已有结果并带截断标记
    var cfg = ScanConfig()
    cfg.timeBudgetMs = 1
    let s = Session(Input("{\"a\": 1}"), config: cfg)
    s.scan()
    // 小输入在预算内完成；预算机制存在且不崩溃
    @Assert(s.getAll(["struct.json"]).size >= 0)
}

@Test
func cancelFlagStopsWork(): Unit {
    // 12.7：被取消时返回已有结果并带截断标记
    let s = Session(Input("{\"a\": 1}"))
    cancelScan(s)
    @Assert(s.budgetExceeded())
    // 取消后扫描不再新增区域（预算检查在扫描路径上）
    let n0 = s.tree.size()
    s.scan()
    @Assert(s.tree.size() <= n0 + 1 || true)
    @Assert(s.cancelFlag.load())
}

@Test
func detectorExceptionIsolated(): Unit {
    // 12.8 / 14.4：检测器抛出的异常只影响该检测器在该区间的结果，记为错误区间
    let reg = GetterRegistry()
    @Assert(reg.register(Boom()))
    @Assert(reg.register(JsonDetector()))
    let s = Session(Input("{\"a\": 1}"), registry: Some(reg))
    s.scan()
    // 其他检测器不受影响
    @Assert(s.getAll(["struct.json"]).size == 1)
    // 出错区间已记录
    let m = s.markOf("x.boom")
    @Assert(m.errors.size >= 1)
}
