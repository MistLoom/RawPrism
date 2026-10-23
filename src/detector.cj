// 检测器与获取器接口（9.1）、检测上下文、物化上下文、注册表。
package rawprism

import std.collection.*
import rawprism.object.*
import rawprism.core.*

/// 检测器：在给定区间内识别某种类型并产出区域。
public interface Detector {
    /// 产出的主类型。
    prop typeId: TypeId
    /// 可运行的父区域选择器，空表示整个输入。
    prop within: Array<String>
    /// 需要先完成的类型（9.5）。
    prop dependsOn: Array<TypeId>
    /// 具有权威性的类型（8.3：发现直接成为区域）。
    prop authoritative: Array<TypeId>
    /// 在 scope 内查找并 emit 区域。
    func detect(scope: Span, ctx: DetectContext): Unit
}

/// 获取器：面向用户的接口，声明所需类型并物化结果。
public interface Getter<T> <: Detector {
    /// 把区域转换为目标表示（物化，C6 惰性）。
    func materialize(region: Region, ctx: MaterializeContext): T
}

/// 检测上下文：读取输入、产出区域、登记副产物。
public interface DetectContext {
    /// 当前检测的目标类型。
    prop forType: TypeId
    /// 单字节读取（-1 表示不可用）。
    func byteAt(offset: Int64): Int64
    /// 取区间文本。
    func text(span: Span): String
    /// 输入长度（已接收部分）。
    prop available: Int64
    /// 产出区域（受 maxRegions 上限约束）。
    func emit(span: Span, typeId: TypeId, confidence: Float64,
              attributes: HashMap<String, String>): Region
    /// 登记候选区间（未经本检测器验证的其他类型区间）。
    func addCandidate(span: Span, typeId: TypeId): Unit
    /// 以权威身份登记区域（8.3：检测器对该类型声明了权威性）。
    func emitAuthoritative(span: Span, typeId: TypeId, confidence: Float64): Region
    /// 登记否定区间（已验证未命中）。
    func addNegative(span: Span): Unit
    /// 登记错误区间（检测出错）。
    func addError(span: Span): Unit
    /// 标记截断。
    func markTruncated(): Unit
    /// 是否已被取消或超时（12.7）。
    prop cancelled: Bool
    /// 共享预扫描：换行位置（5.3：同一信息只计算一次）。
    func lineStarts(): ArrayList<Int64>
    /// 运行中的会话（供嵌套获取器读取其他类型结果）。
    prop session: SessionLike
}

/// 会话只读视图（嵌套获取器用，9.5）。
public interface SessionLike {
    /// 某类型已登记的区域（触发该类型的按需扫描）。
    func regionsOf(typeIdText: String): ArrayList<Region>
    /// 区域树根。
    prop regionTree: RegionTree
    /// 输入字节快照（供检测器读取）。
    func inputBytes(): Array<UInt8>
    /// 扫描配置。
    func scanConfig(): ScanConfig
    /// 区域的对象视图（供嵌套获取器读取）。
    func objectOf(region: Region): Obj
}

/// 物化上下文（C6：惰性物化）。
public interface MaterializeContext {
    /// 取区间原文。
    func text(span: Span): String
    /// 区域的对象视图（按需构建并缓存）。
    func objectOf(region: Region): Obj
    /// 物化大小是否超限。
    func withinBudget(size: Int64): Bool
}

/// 获取器注册表：负责依赖排序与循环依赖拒绝（9.5）。
public class GetterRegistry {
    /// 注册顺序保持；执行顺序按依赖拓扑排序。
    internal let entries: ArrayList<Detector>
    internal var orderedCache: Option<Array<Detector>> = None

    public init() {
        this.entries = ArrayList<Detector>()
    }

    /// 注册检测器。返回是否成功（循环依赖拒绝）。
    public func register(d: Detector): Bool {
        // 拒绝重复注册同一类型（按类型名判重）
        for (e in entries) {
            if (e.typeId.text == d.typeId.text) {
                return true
            }
        }
        entries.add(d)
        orderedCache = None
        topoSort()
    }

    /// 按依赖关系拓扑排序；存在循环依赖时返回 false。
    public func topoSort(): Bool {
        let names = ArrayList<String>()
        for (e in entries) {
            names.add(e.typeId.text)
        }
        // visited: 0 未访问 1 进行中 2 完成
        let visited = HashMap<String, Int64>()
        let out = ArrayList<Detector>()
        var cyclic = false

        func visit(d: Detector): Unit {
            let key = d.typeId.text
            if (let Some(st) <- visited.get(key)) {
                if (st == 1) {
                    cyclic = true
                }
                return
            }
            visited[key] = 1
            for (dep in d.dependsOn) {
                for (e in entries) {
                    if (e.typeId.text == dep.text) {
                        visit(e)
                        break
                    }
                }
                // 未注册的依赖忽略（内置依赖可能缺失）
            }
            visited[key] = 2
            out.add(d)
        }

        for (e in entries) {
            visit(e)
        }
        if (cyclic) {
            return false
        }
        entries.clear()
        for (d in out) {
            entries.add(d)
        }
        orderedCache = Some(out.toArray())
        true
    }

    /// 拓扑排序后的检测器列表。
    public func ordered(): Array<Detector> {
        if (let Some(o) <- orderedCache) {
            return o
        }
        let _ = topoSort()
        if (let Some(o) <- orderedCache) {
            return o
        }
        entries.toArray()
    }

    /// 找到产出某类型的检测器。
    public func detectorFor(typeIdText: String): Option<Detector> {
        for (d in ordered()) {
            if (d.typeId.text == typeIdText) {
                return Some(d)
            }
        }
        None
    }
}
