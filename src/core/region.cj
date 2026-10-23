// 区域与区域树。
package rawprism.core

import std.collection.*

/// 区域：分类结果的基本单元，区间 + 类型 + 置信度 + 属性 + 子区域。
/// 已发布的区域只追加、不修改，以支持并发读取（第 7 节）。
public class Region {
    public let span: Span
    public let typeId: TypeId
    public let confidence: Float64
    public let attributes: HashMap<String, String>
    public let children: ArrayList<Region>
    /// 区域是否已闭合（分段输入时输入未结束可能未闭合）。
    public var complete: Bool
    /// 因资源上限被截断（C7）。
    public var truncated: Bool
    /// 该区间检测出错（14.4：畸形输入记为错误区间，不使会话失败）。
    public var errored: Bool
    /// 区域同一性标识（引用相等判断用）。
    internal let uid: Int64
    public static var uidSeq: Int64 = 0

    public init(span: Span, typeId: TypeId, confidence!: Float64 = 1.0,
                attributes!: HashMap<String, String> = HashMap<String, String>()) {
        this.span = span
        this.typeId = typeId
        this.confidence = confidence
        this.attributes = attributes
        this.children = ArrayList<Region>()
        this.complete = true
        this.truncated = false
        this.errored = false
        Region.uidSeq += 1
        this.uid = Region.uidSeq
    }

    public prop start: Int64 {
        get() { span.start }
    }

    public prop end: Int64 {
        get() { span.end }
    }

    public prop typeName: String {
        get() { typeId.text }
    }

    /// 是否包含某偏移。
    public func contains(offset: Int64): Bool {
        span.contains(offset)
    }
}

/// 区域树：按包含关系组织的区域集合。
/// 存储：顶层区域列表（按位置有序），子区域挂在各自 Region 上，内存与区域数量成线性关系。
public class RegionTree {
    public let roots: ArrayList<Region>
    /// 用于按位置二分查询的平铺索引（惰性维护）。
    internal let flat: ArrayList<Region>
    internal var flatDirty: Bool

    public init() {
        this.roots = ArrayList<Region>()
        this.flat = ArrayList<Region>()
        this.flatDirty = true
    }

    /// 添加顶层区域（调用方保证互不重合包含冲突；同级允许重叠）。
    public func addRoot(region: Region): Unit {
        roots.add(region)
        flatDirty = true
    }

    /// 遍历序：位置升序；起点相同时外层区域优先；再按 TypeId 字典序。
    public func ordered(): ArrayList<Region> {
        let out = ArrayList<Region>()
        collectOrdered(roots, out)
        out
    }

    internal func collectOrdered(list: ArrayList<Region>, out: ArrayList<Region>): Unit {
        let copy = ArrayList<Region>()
        for (r in list) {
            copy.add(r)
        }
        sortByKey(copy)
        for (r in copy) {
            out.add(r)
            collectOrdered(r.children, out)
        }
    }

    public func sortByKeyPublic(list: ArrayList<Region>): Unit {
        sortByKey(list)
    }

    internal func sortByKey(list: ArrayList<Region>): Unit {
        // 简单插入排序：区域数量在树中逐层通常有限，且保持稳定性
        for (i in 1..list.size) {
            let key = list[i]
            var j = i - 1
            while (j >= 0 && regionBefore(key, list[j])) {
                list[j + 1] = list[j]
                j -= 1
            }
            list[j + 1] = key
        }
    }

    internal func regionBefore(a: Region, b: Region): Bool {
        if (a.start != b.start) {
            return a.start < b.start
        }
        // 起点相同：外层（更长的区间）优先
        if (a.end != b.end) {
            return a.end > b.end
        }
        return a.typeId.text < b.typeId.text
    }

    /// 点查询：包含某偏移的区域链（外层在前）。
    public func chainAt(offset: Int64): ArrayList<Region> {
        let out = ArrayList<Region>()
        for (r in roots) {
            if (r.contains(offset)) {
                out.add(r)
                chainInto(r, offset, out)
            }
        }
        out
    }

    internal func chainInto(region: Region, offset: Int64, out: ArrayList<Region>): Unit {
        for (c in region.children) {
            if (c.contains(offset)) {
                out.add(c)
                chainInto(c, offset, out)
            }
        }
    }

    /// 区间查询：与某区间相交的全部区域（遍历序）。
    public func intersecting(s: Span): ArrayList<Region> {
        let out = ArrayList<Region>()
        for (r in ordered()) {
            if (r.span.intersects(s)) {
                out.add(r)
            }
        }
        out
    }

    /// 按类型选择器查询（遍历序）。
    public func bySelectors(selectors: Array<String>): ArrayList<Region> {
        let out = ArrayList<Region>()
        for (r in ordered()) {
            if (r.typeId.matchesAny(selectors)) {
                out.add(r)
            }
        }
        out
    }

    /// 同级重叠区域（7 / 17：同级允许重叠，须可查询）。
    /// 返回与 region 同层且区间相交的其他区域（不含自身），按遍历序排列。
    /// 遍历序即当前实现的确定性优先级：起点升序，起点相同外层优先，再按 TypeId 字典序。
    public func overlapping(region: Region): ArrayList<Region> {
        let out = ArrayList<Region>()
        siblingsOf(region, region.span, out)
        out
    }

    /// 某区间相交的全部同层区域（供 overlap 查询复用）。
    internal func siblingsOf(region: Region, s: Span, out: ArrayList<Region>): Unit {
        let list = containingList(region)
        for (r in list) {
            if (!sameRegion(r, region) && r.span.intersects(s)) {
                out.add(r)
            }
        }
    }

    internal func containingList(region: Region): ArrayList<Region> {
        let found = findSiblings(roots, region)
        if (let Some(list) <- found) {
            return list
        }
        return roots
    }

    internal func findSiblings(list: ArrayList<Region>, region: Region): ?ArrayList<Region> {
        if (findIn(list, region)) {
            return list
        }
        for (r in list) {
            if (let Some(sub) <- findSiblings(r.children, region)) {
                return sub
            }
        }
        None
    }

    internal func findIn(list: ArrayList<Region>, region: Region): Bool {
        for (r in list) {
            if (sameRegion(r, region)) {
                return true
            }
        }
        false
    }

    internal func sameRegion(a: Region, b: Region): Bool {
        a.uid == b.uid
    }

    /// 区域总数。
    public func size(): Int64 {
        countOf(roots)
    }

    internal func countOf(list: ArrayList<Region>): Int64 {
        var n: Int64 = 0
        for (r in list) {
            n += 1
            n += countOf(r.children)
        }
        n
    }
}
