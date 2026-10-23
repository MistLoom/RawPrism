// 会话：扫描状态容器（第 2 节），持有区域树、类型标记和物化缓存。
// 实现：粗分类 → 细分类调度 → 单次扫描（C3）→ 副产物登记（C4）→ 获取器 API。
package rawprism

import std.collection.*
import rawprism.core.*
import std.sync.*
import std.time.*
import rawprism.parse.*
import rawprism.object.*

/// 会话。
public class Session <: SessionLike {
    public let input: Input
    public let config: ScanConfig
    public let registry: GetterRegistry
    /// 区域树。
    public let tree: RegionTree
    /// 类型标记：typeId 文本 -> 标记。
    public let marks: HashMap<String, TypeMark>
    /// 物化缓存：region 对象 -> 对象视图（C6）。
    internal let objCache: HashMap<Int64, Obj>
    /// 截断标记（C7：超限时带截断标记的部分结果）。
    public var truncated: Bool = false
    /// 取消标记。
    public let cancelFlag: AtomicBool = AtomicBool(false)
    /// 开始时间（时间预算用）。
    internal let startAt: MonoTime = MonoTime.now()
    /// 区域计数（maxRegions）。
    internal var regionCount: Int64 = 0
    /// 换行位置预扫描缓存。
    internal var lineIndexShared: Option<LineIndex> = None
    /// 并发互斥：保护 marks 与树的写入。
    internal let lock: Mutex = Mutex()

    public init(input: Input, config!: ScanConfig = ScanConfig(),
                registry!: Option<GetterRegistry> = None) {
        this.input = input
        this.config = config
        this.registry = if (let Some(r) <- registry) { r } else { defaultRegistry() }
        this.tree = RegionTree()
        this.marks = HashMap<String, TypeMark>()
        this.objCache = HashMap<Int64, Obj>()
    }

    // ---------- SessionLike ----------

    public prop regionTree: RegionTree {
        get() { tree }
    }

    public func inputBytes(): Array<UInt8> {
        input.toBytes()
    }

    public func scanConfig(): ScanConfig {
        config
    }

    /// 某类型已登记的区域（触发按需扫描，8.2）。
    public func regionsOf(typeIdText: String): ArrayList<Region> {
        requestType(TypeId(typeIdText), Span(0, input.available))
        if (let Some(m) <- marks.get(typeIdText)) {
            return m.regions
        }
        ArrayList<Region>()
    }

    // ---------- 扫描 ----------

    /// 执行扫描：粗分类 + 细分类。可重复调用（幂等：已覆盖区间不重扫）。
    public func scan(): Session {
        // 粗分类确定顶层区域（5.1）
        let root = coarseRootType()
        requestType(root, Span(0, input.available))
        // 细分类：按依赖序调度全部注册检测器（5.2）；各检测器受 within 限定
        for (d in registry.ordered()) {
            if (budgetExceeded()) {
                truncated = true
                break
            }
            requestType(d.typeId, Span(0, input.available))
        }
        this
    }

    /// 粗分类（5.1）：确定顶层区域类型。
    public func coarseRootType(): TypeId {
        if (let None <- coarseCache) {
            coarseCache = TypeId(coarseClassify())
        }
        if (let Some(t) <- coarseCache) {
            return t
        }
        TypeId("text.plain")
    }

    internal var coarseCache: Option<TypeId> = None

    internal func coarseClassify(): String {
        let data = input.toBytes()
        let n = data.size
        if (n == 0) {
            return "text.plain"
        }
        // 整体为合法 JSON（5.1 第一行）
        let jr = tryParseJson(data, 0, limits: limitsOf(config))
        if (jr.ok) {
            return "struct.json"
        }
        // HTML 文档
        if (looksLikeHtmlDocument(data, 0, n)) {
            return "markup.html"
        }
        // Markdown：front matter / 标题 / 围栏代码块
        if (looksLikeMarkdown(data, 0, n)) {
            return "text.md"
        }
        "text.plain"
    }

    /// 获取类型标记（不存在则创建）。
    public func markOf(typeIdText: String): TypeMark {
        if (let Some(m) <- marks.get(typeIdText)) {
            return m
        }
        let m = TypeMark(typeIdText)
        marks[typeIdText] = m
        m
    }

    /// 时间预算检查（12.7）。
    public func budgetExceeded(): Bool {
        if (cancelFlag.load()) {
            return true
        }
        if (config.timeBudgetMs > 0) {
            let elapsedMs = (MonoTime.now() - startAt).toMilliseconds()
            if (elapsedMs > config.timeBudgetMs) {
                truncated = true
                return true
            }
        }
        false
    }

    /// 请求某类型在某区间上的结果（8.2 获取流程）。
    public func requestType(t: TypeId, scope: Span): Unit {
        if (budgetExceeded()) {
            return
        }
        let m = markOf(t.text)
        // 1. 计算未覆盖部分
        let uncovered = m.uncovered(scope)
        if (uncovered.isEmpty()) {
            return
        }
        // 2. 找检测器
        if (let None <- registry.detectorFor(t.text)) {
            // 无检测器：只登记覆盖，状态部分
            for (u in uncovered) {
                m.addCovered(u)
            }
            m.status = MarkStatus.Partial
            return
        }
        let det = registry.detectorFor(t.text).getOrThrow()
        // 3. 在未覆盖部分运行，优先验证候选区间
        for (u in uncovered) {
            if (budgetExceeded()) {
                return
            }
            // 候选优先
            let cands = m.candidatesIn(u)
            for (c in cands) {
                if (budgetExceeded()) {
                    return
                }
                runDetector(det, t, c)
            }
            let rest = m.uncovered(u)
            for (r in rest) {
                if (budgetExceeded()) {
                    return
                }
                runDetector(det, t, r)
            }
        }
        // 状态更新
        let nowCovered = m.uncovered(scope).isEmpty()
        if (nowCovered) {
            m.status = MarkStatus.Done
        } else {
            m.status = MarkStatus.Partial
        }
    }

    /// 运行检测器（带错误隔离，12.8 / 14.4）。
    internal func runDetector(det: Detector, t: TypeId, scope: Span): Unit {
        let m = markOf(t.text)
        m.addCovered(scope)
        if (scope.isEmpty()) {
            return
        }
        let ctx = DetectCtx(this, t)
        try {
            det.detect(scope, ctx)
        } catch (e: Exception) {
            // 异常只影响该检测器在该区间的结果：记为错误区间
            m.addError(scope)
            ctx.addError(scope)
        }
        // 清理已消费的候选区间
        let stillCand = ArrayList<Span>()
        for (c in m.candidates) {
            var consumed = false
            for (r in m.regions) {
                if (r.span.contains(c)) {
                    consumed = true
                    break
                }
            }
            if (!consumed) {
                stillCand.add(c)
            }
        }
        m.candidates.clear()
        for (c in stillCand) {
            m.candidates.add(c)
        }
    }

    // ---------- 输入保留报告（4.4.6：超限行为可预期、可报告） ----------

    /// 当前驻留内存的字节数。
    public func retainedBytes(): Int64 {
        input.retainedBytes()
    }

    /// 因超出保留上限而丢弃、无法再物化的区间（只读副本）。
    public func droppedSpans(): ArrayList<Span> {
        input.droppedSpans()
    }

    /// 输入是否仍完整可物化。
    public func fullyRetained(): Bool {
        input.fullyRetained()
    }

    // ---------- 内部：区域产出 ----------

    /// 产出区域（受 maxRegions 约束），挂到区域树。
    internal func emitRegion(parent: Option<Region>, span: Span, t: TypeId,
                             confidence: Float64, attributes: HashMap<String, String>,
                             complete: Bool): Region {
        let r = Region(span, t, confidence: confidence, attributes: attributes)
        r.complete = complete
        if (span.length > config.maxStructureLength) {
            r.truncated = true
            truncated = true
        }
        lock.lock()
        try {
            if (regionCount >= config.maxRegions) {
                truncated = true
                return r
            }
            regionCount += 1
        } finally {
            lock.unlock()
        }
        if (confidence < config.confidenceThreshold) {
            return r
        }
        let m = markOf(t.text)
        m.regions.add(r)
        lock.lock()
        try {
            if (let Some(p) <- parent) {
                p.children.add(r)
            } else {
                tree.addRoot(r)
            }
        } finally {
            lock.unlock()
        }
        r
    }

    // ---------- 获取器 API ----------

    /// 通用获取：按类型选择器取区域结果（9.3）。
    public func getAll(selectors: Array<String>): ArrayList<RegionResult> {
        let out = ArrayList<RegionResult>()
        // 顶层与各检测器类型都请求一遍（按需）
        let seen = HashSet<String>()
        for (sel in selectors) {
            for (d in registry.ordered()) {
                let dt = d.typeId
                if (dt.matches(sel)) {
                    if (!seen.contains(dt.text)) {
                        seen.add(dt.text)
                        requestType(dt, Span(0, input.available))
                    }
                }
            }
        }
        // 顶层粗分类类型也纳入
        let root = coarseRootType()
        if (root.matchesAny(selectors) && !seen.contains(root.text)) {
            seen.add(root.text)
            requestType(root, Span(0, input.available))
        }
        for (r in tree.ordered()) {
            if (r.typeId.matchesAny(selectors)) {
                out.add(RegionResult(r, this))
            }
        }
        out
    }

    /// 第一个匹配结果（9.2 first）。
    public func first(selectors: Array<String>): ?RegionResult {
        let all = getAll(selectors)
        if (all.size == 0) {
            return None
        }
        Some(all[0])
    }

    /// 列出输入中出现的类型及数量（9.3）。
    public func typeCounts(): ArrayList<(String, Int64)> {
        let counts = HashMap<String, Int64>()
        for (r in tree.ordered()) {
            let k = r.typeId.text
            if (let Some(c) <- counts.get(k)) {
                counts[k] = c + 1
            } else {
                counts[k] = 1
            }
        }
        let out = ArrayList<(String, Int64)>()
        for ((k, v) in counts) {
            out.add((k, v))
        }
        sortByPair(out)
        out
    }

    internal func sortByPair(list: ArrayList<(String, Int64)>): Unit {
        for (i in 1..list.size) {
            let key = list[i]
            var j = i - 1
            while (j >= 0 && list[j][0] > key[0]) {
                list[j + 1] = list[j]
                j -= 1
            }
            list[j + 1] = key
        }
    }

    /// 混合类型遍历：按位置顺序遍历全部区域（11）。
    public func walk(visitor: (Region, Int64) -> WalkControl): Unit {
        let depth = 0
        walkInto(tree.roots, visitor, depth)
    }

    internal func walkInto(list: ArrayList<Region>, visitor: (Region, Int64) -> WalkControl, depth: Int64): Bool {
        let sorted = ArrayList<Region>()
        for (r in list) {
            sorted.add(r)
        }
        tree.sortByKeyPublic(sorted)
        for (r in sorted) {
            let c = visitor(r, depth)
            if (walkCtrlEq(c, WalkControl.Stop)) {
                return false
            }
            if (walkCtrlEq(c, WalkControl.SkipSubtree)) {
                continue
            }
            if (!walkInto(r.children, visitor, depth + 1)) {
                return false
            }
        }
        true
    }

    /// 点查询：包含某偏移的区域链（7）。
    public func chainAt(offset: Int64): ArrayList<Region> {
        tree.chainAt(offset)
    }

    /// 区间查询：与某区间相交的区域（7）。
    public func intersecting(s: Span): ArrayList<Region> {
        tree.intersecting(s)
    }

    /// 对象视图（惰性物化并缓存，C6）。
    public func objectOf(region: Region): Obj {
        if (let Some(o) <- objCache.get(hashOf(region))) {
            return o
        }
        let o = buildObject(region)
        objCache[hashOf(region)] = o
        o
    }

    internal func hashOf(region: Region): Int64 {
        region.span.start * 1000003 + region.span.end
    }

    /// 按区域类型构建对象视图（9.3 目标格式规则）。
    internal func buildObject(region: Region): Obj {
        let data = input.toBytes()
        let s = region.span
        let t = region.typeId.text
        if (t == "text.md.frontmatter" || t.startsWith("text.md.frontmatter")) {
            // front matter 按其内部格式映射（10.3），此处为 YAML
            let yr = parseYaml(data, start: s.start, end: s.end, limits: limitsOf(config))
            if (yr.ok && yr.documents.size > 0) {
                if (yr.documents.size == 1) {
                    return yr.documents[0].root
                }
                let seq = ObjSeq(span: s, formatTag: "yaml", ref: Some(input))
                for (d in yr.documents) {
                    seq.add(d.root)
                }
                return seq
            }
        }
        if (t == "struct.json") {
            let r = tryParseJson(data, s.start, limits: limitsOf(config))
            if (r.ok) {
                return r.value.getOrThrow()
            }
        }
        if (t == "struct.ndjson") {
            let nd = parseNdjson(data[s.start..s.end], limits: limitsOf(config))
            let seq = ObjSeq(span: s, formatTag: "ndjson", ref: Some(input))
            for ((v, _) in nd.values) {
                seq.add(v)
            }
            return seq
        }
        if (t == "struct.yaml") {
            let yr = parseYaml(data, start: s.start, end: s.end, limits: limitsOf(config))
            if (yr.ok && yr.documents.size > 0) {
                if (yr.documents.size == 1) {
                    return yr.documents[0].root
                }
                let seq = ObjSeq(span: s, formatTag: "yaml", ref: Some(input))
                for (d in yr.documents) {
                    seq.add(d.root)
                }
                return seq
            }
        }
        if (t == "struct.toml") {
            let tr = parseToml(data, start: s.start, end: s.end, limits: limitsOf(config))
            if (tr.ok) {
                return tr.root
            }
        }
        if (t == "struct.csv") {
            let cr = parseCsv(data, start: s.start, end: s.end, limits: limitsOf(config))
            if (cr.ok) {
                // 有表头：Mapping 的 Sequence；否则 Sequence 的 Sequence（10.3）
                if (cr.header.size > 0) {
                    let seq = ObjSeq(span: s, formatTag: "csv", ref: Some(input))
                    for (row in cr.rows) {
                        let map = ObjMap(span: row.span, formatTag: "csv:record", ref: Some(input))
                        var i = 0
                        for (cell in row.items()) {
                            if (i < cr.header.size) {
                                map.put(cr.header[i], cell)
                            }
                            i += 1
                        }
                        seq.add(map)
                    }
                    return seq
                }
                let seq = ObjSeq(span: s, formatTag: "csv", ref: Some(input))
                for (row in cr.rows) {
                    seq.add(row)
                }
                return seq
            }
        }
        if (t == "struct.xml" || t.startsWith("markup.html")) {
            let isHtml = t.startsWith("markup.html")
            let xr = parseXml(data, start: s.start, end: s.end, html: isHtml, limits: limitsOf(config))
            if (xr.ok) {
                if (xr.roots.size == 1) {
                    return xmlToObj(xr.roots[0], Some(input))
                }
                let seq = ObjSeq(span: s, formatTag: t, ref: Some(input))
                for (rootNode in xr.roots) {
                    seq.add(xmlToObj(rootNode, Some(input)))
                }
                return seq
            }
        }
        if (t.startsWith("code.block")) {
            // 代码块：若声明 lang=json/yaml 等可试解析（5.2）
            if (let Some(lang) <- region.typeId.params.get("lang")) {
                let inner = region.attributes.get("content")
                var cs = s
                if (let Some(c) <- inner) {
                    if (let Some(sp) <- parseSpanAttr(c)) {
                        cs = sp
                    }
                }
                if (lang == "json") {
                    let r = tryParseJson(data, cs.start, limits: limitsOf(config))
                    if (r.ok) {
                        return r.value.getOrThrow()
                    }
                } else if (lang == "yaml" || lang == "yml") {
                    let yr = parseYaml(data, start: cs.start, end: cs.end, limits: limitsOf(config))
                    if (yr.ok && yr.documents.size > 0) {
                        return yr.documents[0].root
                    }
                } else if (lang == "toml") {
                    let tr = parseToml(data, start: cs.start, end: cs.end, limits: limitsOf(config))
                    if (tr.ok) {
                        return tr.root
                    }
                } else if (lang == "csv") {
                    let cr = parseCsv(data, start: cs.start, end: cs.end, limits: limitsOf(config))
                    if (cr.ok && cr.rows.size > 0) {
                        let seq = ObjSeq(span: cs, formatTag: "csv", ref: Some(input))
                        for (row in cr.rows) {
                            seq.add(row)
                        }
                        return seq
                    }
                }
            }
            return ObjText(input.text(s), escaped: false, span: s, formatTag: "code", ref: Some(input))
        }
        if (t.startsWith("text.md") || t == "text.plain" || t.startsWith("entity.")) {
            return ObjText(input.text(s), escaped: false, span: s, formatTag: t, ref: Some(input))
        }
        // 默认：原文文本视图
        ObjText(input.text(s), escaped: false, span: s, formatTag: t, ref: Some(input))
    }

    /// 物化上下文。
    public func materializeCtx(): MaterializeContext {
        MatCtx(this)
    }

    /// 共享预扫描：换行位置（5.3：同一信息在一个输入上只计算一次）。
    public func lineStartsShared(): ArrayList<Int64> {
        if (let Some(li) <- lineIndexShared) {
            return li.starts
        }
        let li = LineIndex(input.toBytes())
        lineIndexShared = li
        li.starts
    }

    /// 通用共享预扫描（5.3 / 17）：同一输入上按 key 只计算一次。
    /// 多个检测器与多实体需要相同的底层信息（换行位置、括号位置等）时，
    /// 通过本方法取共享结果：首次调用计算并缓存，之后直接命中。
    /// 缓存随会话生命周期，输入只读，因此结果不失效。
    public func prescan<T>(key: String, compute: () -> T): T {
        lock.lock()
        try {
            if (let Some(v) <- prescanCache.get(key)) {
                if (let Some(t) <- (v as T)) {
                    return t
                }
            }
            // 未命中：在锁外计算可能长时间持有锁，这里直接在锁内计算，
            // 保证同一 key 只计算一次（并发请求串行等待）。
            let v = compute()
            prescanCache[key] = v
            return v
        } finally {
            lock.unlock()
        }
    }
    /// 共享预扫描缓存：key -> 计算结果（5.3）。
    internal let prescanCache: HashMap<String, Any> = HashMap<String, Any>()
}

internal func parseSpanAttr(s: String): ?Span {
    // 属性形如 "start:end"
    let colon = s.indexOf(":")
    if (let None <- colon) {
        return None
    }
    let c = colon.getOrThrow()
    let a = parseInt64(s[0..c])
    let b = parseInt64(s[c + 1..s.size])
    if (let Some(x) <- a) {
        if (let Some(y) <- b) {
            return Some(Span(x, y))
        }
    }
    None
}

/// 区域结果：区域信息 + 惰性的值（9.2：只读取区域信息不触发物化）。
public class RegionResult {
    public let region: Region
    internal let session: Session

    public init(region: Region, session: Session) {
        this.region = region
        this.session = session
    }

    /// 区域类型。
    public prop typeId: TypeId {
        get() { region.typeId }
    }

    /// 区间。
    public prop span: Span {
        get() { region.span }
    }

    /// 原文文本（惰性物化）。
    public func text(): String {
        session.objectOf(region).rawText()
    }

    /// 对象视图（惰性物化，仅树形类型有意义）。
    public func value(): Obj {
        session.objectOf(region)
    }
}

/// 检测上下文实现。
internal class DetectCtx <: DetectContext {
    internal let holder: Session
    internal let target: TypeId
    /// 当前 emit 的父区域（由调度器在运行检测器时设置）。
    internal var currentParent: Option<Region> = None

    public init(session: Session, target: TypeId) {
        this.holder = session
        this.target = target
    }

    public prop forType: TypeId {
        get() { target }
    }

    public func byteAt(offset: Int64): Int64 {
        holder.input.byteAt(offset)
    }

    public func text(span: Span): String {
        holder.input.text(span)
    }

    public prop available: Int64 {
        get() { holder.input.available }
    }

    public func emit(span: Span, typeId: TypeId, confidence: Float64,
                     attributes: HashMap<String, String>): Region {
        holder.emitRegion(currentParent, span, typeId, confidence, attributes, true)
    }

    public func addCandidate(span: Span, typeId: TypeId): Unit {
        let m = holder.markOf(typeId.text)
        // 已是该类型区域的不重复登记
        for (r in m.regions) {
            if (r.span.contains(span)) {
                return
            }
        }
        m.addCandidate(span)
    }

    public func emitAuthoritative(span: Span, typeId: TypeId, confidence: Float64): Region {
        let r = holder.emitRegion(currentParent, span, typeId, confidence,
            HashMap<String, String>(), true)
        let m = holder.markOf(typeId.text)
        m.addCovered(span)
        r
    }

    public func addNegative(span: Span): Unit {
        holder.markOf(target.text).addNegative(span)
    }

    public func addError(span: Span): Unit {
        holder.markOf(target.text).addError(span)
        holder.truncated = holder.truncated
    }

    public func markTruncated(): Unit {
        holder.truncated = true
    }

    public prop cancelled: Bool {
        get() { holder.budgetExceeded() }
    }

    /// 共享预扫描：换行位置（5.3，输入级缓存只算一次）。
    public func lineStarts(): ArrayList<Int64> {
        holder.lineStartsShared()
    }

    public prop session: SessionLike {
        get() { holder }
    }
}

/// 物化上下文实现。
internal class MatCtx <: MaterializeContext {
    internal let session: Session

    public init(session: Session) {
        this.session = session
    }

    public func text(span: Span): String {
        session.input.text(span)
    }

    public func objectOf(region: Region): Obj {
        session.objectOf(region)
    }

    public func withinBudget(size: Int64): Bool {
        size <= session.config.maxMaterializeBytes
    }
}

/// HTML 文档形状判断。
public func looksLikeHtmlDocument(data: Array<UInt8>, start: Int64, end: Int64): Bool {
    var i = start
    while (i < end) {
        if (data[i] == 60) { // '<'
            // <!doctype html 或 <html
            if (i + 1 < end && (data[i + 1] == 33 || data[i + 1] == 104 || data[i + 1] == 72)) {
                if (startsWithAscii(data, i, "<!doctype") || startsWithAscii(data, i, "<!DOCTYPE") ||
                    startsWithAscii(data, i, "<html") || startsWithAscii(data, i, "<HTML")) {
                    return true
                }
            }
            return false
        }
        if (data[i] != 32 && data[i] != 9 && data[i] != 10 && data[i] != 13) {
            return false
        }
        i += 1
    }
    false
}

/// Markdown 形状判断：front matter / 标题 / 围栏代码块。
public func looksLikeMarkdown(data: Array<UInt8>, start: Int64, end: Int64): Bool {
    var i = start
    while (i < end) {
        if (lineStartsWith(data, i, end, "---")) {
            return true
        }
        if (data[i] == 35) {
            var k = i
            var hashes = 0
            while (k < end && data[k] == 35) {
                hashes += 1
                k += 1
            }
            if (hashes >= 1 && hashes <= 6 && (k >= end || data[k] == 32 || data[k] == 10)) {
                return true
            }
            return false
        }
        if (data[i] == 96 || data[i] == 126) {
            var k = i
            var n = 0
            while (k < end && (data[k] == 96 || data[k] == 126)) {
                n += 1
                k += 1
            }
            if (n >= 3) {
                return true
            }
            return false
        }
        if (data[i] != 32 && data[i] != 9 && data[i] != 10 && data[i] != 13) {
            return false
        }
        i += 1
    }
    false
}

internal func startsWithAscii(data: Array<UInt8>, pos: Int64, word: String): Bool {
    let w = word.toArray()
    if (pos + w.size > data.size) {
        return false
    }
    var i: Int64 = 0
    while (i < w.size) {
        if (data[pos + i] != w[i]) {
            return false
        }
        i += 1
    }
    true
}
