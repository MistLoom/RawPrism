// 内置检测器：结构检测器（JSON/NDJSON/YAML/TOML/CSV/XML）、
// 标记检测器（HTML）、文本检测器（Markdown）、实体检测器（URL/Email）。
// 副产物登记（C4）：HTML href/src、Markdown 链接、JSON 字符串值中的 URL。
package rawprism

import std.collection.*
import rawprism.core.*
import rawprism.parse.*
import rawprism.object.*

/// 共享预扫描容器（5.3）：换行位置只计算一次。
public class LineIndex {
    public let starts: ArrayList<Int64>

    public init(data: Array<UInt8>) {
        this.starts = ArrayList<Int64>()
        starts.add(0)
        var i: Int64 = 0
        while (i < data.size) {
            if (data[i] == 10) {
                starts.add(i + 1)
            }
            i += 1
        }
    }
}

/// 默认注册表：全部内置检测器 + 依赖拓扑排序。
public func defaultRegistry(): GetterRegistry {
    let r = GetterRegistry()
    let _ = r.register(JsonDetector())
    let _ = r.register(NdjsonDetector())
    let _ = r.register(YamlDetector())
    let _ = r.register(TomlDetector())
    let _ = r.register(CsvDetector())
    let _ = r.register(XmlDetector())
    let _ = r.register(HtmlDetector())
    let _ = r.register(MarkdownDetector())
    let _ = r.register(UrlDetector())
    let _ = r.register(EmailDetector())
    let _ = r.topoSort()
    r
}

// ---------- 内置获取器形态（9.2：单类型获取器） ----------

/// 单类型获取器基类：按类型获取并物化。
public abstract class TypedGetter<T> {
    protected let session: Session

    protected init(session: Session) {
        this.session = session
    }

    /// 全部该类型结果。
    public func all(): ArrayList<RegionResult> {
        session.getAll([typeSelector()])
    }

    /// 限定父区域类型的结果。
    public func allWithin(parentSelector: String): ArrayList<RegionResult> {
        let out = ArrayList<RegionResult>()
        for (rr in all()) {
            let chain = session.regionTree.chainAt(rr.region.span.start)
            var within = false
            for (p in chain) {
                if (p.typeId.matches(parentSelector)) {
                    within = true
                    break
                }
            }
            if (within) {
                out.add(rr)
            }
        }
        out
    }

    /// 第一个结果，可能不存在。
    public func first(): ?RegionResult {
        let a = all()
        if (a.size == 0) {
            return None
        }
        Some(a[0])
    }

    protected open func typeSelector(): String {
        "text.plain"
    }
}

/// JSON 文档获取器。
public class JsonDoc <: TypedGetter<Obj> {
    public init(session: Session) {
        super(session)
    }

    protected override func typeSelector(): String {
        "struct.json"
    }

    /// 物化为对象视图。
    public func materialize(region: Region): Obj {
        session.objectOf(region)
    }
}

/// URL 实体获取器。
public class UrlEntity <: TypedGetter<String> {
    public init(session: Session) {
        super(session)
    }

    protected override func typeSelector(): String {
        "entity.url"
    }

    public func materialize(region: Region): String {
        session.input.text(region.span)
    }
}

/// Email 实体获取器。
public class EmailEntity <: TypedGetter<String> {
    public init(session: Session) {
        super(session)
    }

    protected override func typeSelector(): String {
        "entity.email"
    }
}

/// HTML 文档获取器。
public class HtmlDoc <: TypedGetter<Obj> {
    public init(session: Session) {
        super(session)
    }

    protected override func typeSelector(): String {
        "markup.html"
    }

    public func materialize(region: Region): Obj {
        session.objectOf(region)
    }
}

// ---------- 结构检测器 ----------

/// JSON 检测器：在 scope 内寻找嵌入的 JSON 结构（有界试解析，5.2）。
public class JsonDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.json") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        // 顶层整段已是 JSON：直接 emit
        let data = readAll(ctx)
        if (scope.start == 0) {
            let whole = tryParseJson(data, 0, limits: limitsOf(ctxConfig(ctx)))
            if (whole.ok && whole.consumed >= data.size) {
                let _ = ctx.emit(Span(0, whole.consumed), typeId, 1.0, HashMap<String, String>())
                registerJsonStrings(whole.value.getOrThrow(), ctx)
                return
            }
        }
        // 嵌入式：扫描疑似起始
        scanEmbedded(data, scope, ctx)
    }

    /// 在 scope 内寻找以 { 或 [ 开头的疑似 JSON 并试解析（其他获取器不重复检查该区间，C4）。
    func scanEmbedded(data: Array<UInt8>, scope: Span, ctx: DetectContext): Unit {
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            let b = data[i]
            if (b == 123 || b == 91) {
                let r = tryParseJson(data, i, limits: limitsOf(ctxConfig(ctx)))
                if (r.ok) {
                    let sp = Span(i, r.consumed)
                    // 排除已登记区域
                    if (!alreadyCovered(ctx, sp)) {
                        let _ = ctx.emit(sp, typeId, 1.0, HashMap<String, String>())
                        registerJsonStrings(r.value.getOrThrow(), ctx)
                    }
                    i = r.consumed
                    continue
                } else {
                    // 登记否定区间：其他获取器不再重复检查（5.2）
                    ctx.addNegative(Span(i, i + 1))
                }
            }
            i += 1
        }
    }

    /// 副产物登记：JSON 字符串值中像 URL 的登记为 entity.url 候选（8.3）。
    func registerJsonStrings(obj: Obj, ctx: DetectContext): Unit {
        obj.walk({ n: Obj =>
            if (objKindEq(n.kind, ObjKind.KText)) {
                if (let Some(t) <- n.asText()) {
                    if (looksLikeUrlText(t)) {
                        ctx.addCandidate(n.span, TypeId("entity.url"))
                    }
                }
            }
            WalkControl.Continue
        })
    }
}

/// NDJSON 检测器：整段由多行 JSON 值构成。
public class NdjsonDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.ndjson") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let data = readAll(ctx)
        if (data.size == 0 || data.indexOf(10) == None) {
            return
        }
        // 只有顶层未覆盖时才整体判断（避免与 JSON 检测器重复）
        let nd = parseNdjson(data, limits: limitsOf(ctxConfig(ctx)))
        if (nd.errors.size == 0 && nd.values.size >= 2) {
            let covered: Int64 = 0
            let _ = covered
            // 区域覆盖整个 NDJSON 段
            var end: Int64 = 0
            for ((_, sp) in nd.values) {
                if (sp.end > end) {
                    end = sp.end
                }
            }
            let _ = ctx.emit(Span(0, end), typeId, 1.0, HashMap<String, String>())
        }
    }
}

/// YAML 检测器：Markdown front matter（权威）与嵌入的 YAML 块。
public class YamlDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.yaml") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [TypeId("text.md.frontmatter")] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        let md = parseMarkdownBlocks(data, start: scope.start, end: scope.end)
        // front matter（权威发现：直接成为区域）
        if (let Some(fm) <- md.frontMatter) {
            let r = parseYaml(data, start: fm.start, end: fm.end, limits: limitsOf(ctxConfig(ctx)))
            if (r.ok && r.documents.size > 0) {
                let _ = ctx.emit(fm, typeId, 1.0, HashMap<String, String>())
                return
            }
        }
        // 文本中嵌入的 YAML 块：连续 "key: value" 行（保守识别多行块）
        detectEmbeddedYaml(data, scope, ctx)
    }

    func detectEmbeddedYaml(data: Array<UInt8>, scope: Span, ctx: DetectContext): Unit {
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            let le = lineEnd(data, i, scope.end)
            let line = if (le > i) { String.fromUtf8(data[i..le]) } else { "" }
            let t = line.trimAscii()
            // 疑似 YAML：顶层 key: value 形状且至少两行
            if (isYamlKeyValueLine(t)) {
                var j = le + 1
                var last = le
                var lines = 1
                while (j < scope.end) {
                    let le2 = lineEnd(data, j, scope.end)
                    let l2 = if (le2 > j) { String.fromUtf8(data[j..le2]) } else { "" }
                    let t2 = l2.trimAscii()
                    if (t2.isEmpty() || t2 == "---") {
                        break
                    }
                    if (isYamlKeyValueLine(t2) || t2.startsWith("- ")) {
                        lines += 1
                        last = le2
                        j = if (le2 < scope.end) { le2 + 1 } else { scope.end }
                        continue
                    }
                    break
                }
                if (lines >= 2) {
                    let r = parseYaml(data, start: i, end: last + 1, limits: limitsOf(ctxConfig(ctx)))
                    if (r.ok && r.documents.size > 0) {
                        let sp = Span(i, last)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 0.8, HashMap<String, String>())
                        }
                        i = last
                        continue
                    }
                }
            }
            i = if (le < scope.end) { le + 1 } else { scope.end }
        }
    }

    func isYamlKeyValueLine(t: String): Bool {
        if (t.isEmpty() || t.startsWith("#")) {
            return false
        }
        let c = t.indexOf(":")
        if (let Some(pos) <- c) {
            let k = trimAscii(t[0..pos])
            if (k.isEmpty()) {
                return false
            }
            // 键不含空格（保守）
            for (b in k.toArray()) {
                if (b == 32) {
                    return false
                }
            }
            return true
        }
        false
    }
}

/// TOML 检测器：嵌入的 TOML 块（[table] 行引导）。
public class TomlDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.toml") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            let le = lineEnd(data, i, scope.end)
            let line = if (le > i) { String.fromUtf8(data[i..le]) } else { "" }
            let t = line.trimAscii()
            if (t.startsWith("[") && t.endsWith("]")) {
                // 收集连续 TOML 行
                var j = le + 1
                var last = le
                while (j < scope.end) {
                    let le2 = lineEnd(data, j, scope.end)
                    let l2 = if (le2 > j) { String.fromUtf8(data[j..le2]) } else { "" }
                    let t2 = l2.trimAscii()
                    if (t2.isEmpty()) {
                        break
                    }
                    if (isTomlLine(t2)) {
                        last = le2
                        j = if (le2 < scope.end) { le2 + 1 } else { scope.end }
                        continue
                    }
                    break
                }
                if (last > le) {
                    let r = parseToml(data, start: i, end: last + 1, limits: limitsOf(ctxConfig(ctx)))
                    if (r.ok) {
                        let sp = Span(i, last)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 0.7, HashMap<String, String>())
                        }
                        i = last
                        continue
                    }
                }
            }
            i = if (le < scope.end) { le + 1 } else { scope.end }
        }
    }

    func isTomlLine(t: String): Bool {
        if (t.startsWith("#")) {
            return true
        }
        if (t.startsWith("[") && t.endsWith("]")) {
            return true
        }
        let eq = t.indexOf("=")
        if (let Some(p) <- eq) {
            return p > 0
        }
        false
    }
}

/// CSV 检测器：连续多行、行内分隔符数量一致。
public class CsvDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.csv") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            // 跳过空行
            let le0 = lineEnd(data, i, scope.end)
            var blank = true
            var k = i
            while (k < le0) {
                if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                    blank = false
                    break
                }
                k += 1
            }
            if (blank) {
                i = if (le0 < scope.end) { le0 + 1 } else { scope.end }
                continue
            }
            let sep = detectCsvDelimiter(data, i, scope.end)
            if (sep == 44) {
                // 默认逗号；分隔符计数为 0 则不是 CSV
                var c: Int64 = 0
                var m = i
                while (m < le0) {
                    if (data[m] == 44) {
                        c += 1
                    }
                    m += 1
                }
                if (c == 0) {
                    i = if (le0 < scope.end) { le0 + 1 } else { scope.end }
                    continue
                }
            }
            // 收集分隔符计数一致的连续行（至少 2 行）
            let start0 = i
            var last = le0
            var rows = 1
            var counts: Int64 = countChar(data, i, le0, sep)
            var j = if (le0 < scope.end) { le0 + 1 } else { scope.end }
            while (j < scope.end) {
                let le2 = lineEnd(data, j, scope.end)
                var blank2 = true
                var k2 = j
                while (k2 < le2) {
                    if (data[k2] != 32 && data[k2] != 9 && data[k2] != 13) {
                        blank2 = false
                        break
                    }
                    k2 += 1
                }
                if (blank2) {
                    break
                }
                let c2 = countChar(data, j, le2, sep)
                if (c2 == counts && c2 > 0) {
                    rows += 1
                    last = le2
                    j = if (le2 < scope.end) { le2 + 1 } else { scope.end }
                    continue
                }
                break
            }
            if (rows >= 2) {
                let cr = parseCsv(data, start: start0, end: last + 1, delimiter: sep,
                    limits: limitsOf(ctxConfig(ctx)))
                if (cr.ok) {
                    let sp = Span(start0, last)
                    if (!alreadyCovered(ctx, sp)) {
                        let _ = ctx.emit(sp, typeId, 0.8, HashMap<String, String>())
                    }
                    i = last
                    continue
                }
            }
            i = if (le0 < scope.end) { le0 + 1 } else { scope.end }
        }
    }

    func countChar(data: Array<UInt8>, s: Int64, e: Int64, c: UInt8): Int64 {
        var n: Int64 = 0
        var i = s
        var inQ = false
        while (i < e) {
            let b = data[i]
            if (inQ) {
                if (b == 34) {
                    inQ = false
                }
            } else if (b == 34) {
                inQ = true
            } else if (b == c) {
                n += 1
            }
            i += 1
        }
        n
    }
}

/// XML 检测器：以 <tag> 开头的片段。
public class XmlDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("struct.xml") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        var i = scope.start
        while (i < scope.end - 1) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            // 嵌入 XML：'<' 后是字母（且不是 HTML 文档已识别的部分）
            if (data[i] == 60 && isAlpha(data[i + 1]) && !looksLikeHtmlDocument(data, i, scope.end)) {
                let xr = parseXml(data, start: i, end: scope.end, html: false,
                    limits: limitsOf(ctxConfig(ctx)))
                if (xr.ok && xr.roots.size > 0) {
                    // 找最远 root 结束
                    var end: Int64 = i
                    for (r in xr.roots) {
                        if (r.span.end > end) {
                            end = r.span.end
                        }
                    }
                    if (end > i) {
                        let sp = Span(i, end)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 0.8, HashMap<String, String>())
                        }
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }
    }

    func isAlpha(b: UInt8): Bool {
        (b >= 97 && b <= 122) || (b >= 65 && b <= 90)
    }
}

// ---------- 标记检测器 ----------

/// HTML 检测器：顶层 HTML 文档或 Markdown 中的 HTML 块。
public class HtmlDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("markup.html") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    /// href/src 属性值为权威 URL 发现（8.3）。
    public prop authoritative: Array<TypeId> {
        get() { [TypeId("entity.url")] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        // 顶层 HTML 文档
        if (looksLikeHtmlDocument(data, scope.start, scope.end)) {
            let xr = parseXml(data, start: scope.start, end: scope.end, html: true,
                limits: limitsOf(ctxConfig(ctx)))
            if (xr.ok && xr.roots.size > 0) {
                var end: Int64 = scope.start
                for (r in xr.roots) {
                    if (r.span.end > end) {
                        end = r.span.end
                    }
                }
                let _ = ctx.emit(Span(scope.start, end), typeId, 1.0, HashMap<String, String>())
                registerHtmlEntities(xr.roots, ctx)
                return
            }
        }
        // 嵌入 HTML 片段
        var i = scope.start
        while (i < scope.end - 1) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            if (data[i] == 60 && isHtmlAlpha(data[i + 1])) {
                let xr = parseXml(data, start: i, end: scope.end, html: true,
                    limits: limitsOf(ctxConfig(ctx)))
                if (xr.ok && xr.roots.size > 0) {
                    var end: Int64 = i
                    for (r in xr.roots) {
                        if (r.span.end > end) {
                            end = r.span.end
                        }
                    }
                    if (end > i) {
                        let sp = Span(i, end)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 0.9, HashMap<String, String>())
                        }
                        registerHtmlEntities(xr.roots, ctx)
                        i = end
                        continue
                    }
                }
            }
            i += 1
        }
    }

    /// 副产物：href/src 属性值直接作为权威 URL 区域（8.3）。
    func registerHtmlEntities(roots: ArrayList<XmlNode>, ctx: DetectContext): Unit {
        for (rootNode in roots) {
            walkXml(rootNode, { n: XmlNode =>
                for ((k, v, vs) in n.attrs) {
                    if ((k == "href" || k == "src") && !v.isEmpty()) {
                        let _ = ctx.emitAuthoritative(vs, TypeId("entity.url"), 1.0)
                    }
                }
            })
        }
    }

    func walkXml(node: XmlNode, visit: (XmlNode) -> Unit): Unit {
        visit(node)
        for (c in node.children) {
            walkXml(c, visit)
        }
    }

    func isHtmlAlpha(b: UInt8): Bool {
        (b >= 97 && b <= 122) || (b >= 65 && b <= 90)
    }
}

// ---------- 文本检测器 ----------

/// Markdown 检测器：块级结构 + 副产物（front matter、代码块语言、HTML 块、链接）。
public class MarkdownDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("text.md") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    /// front matter 类型权威；URL 候选（链接语法位置）非权威。
    public prop authoritative: Array<TypeId> {
        get() { [TypeId("text.md.frontmatter"), TypeId("text.md.heading"), TypeId("text.md.paragraph"), TypeId("text.md.code"), TypeId("text.md.table")] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        let isRoot = scope.start == 0
        let md = parseMarkdownBlocks(data, start: scope.start, end: scope.end)
        if (md.blocks.size == 0) {
            return
        }
        // 只有整体像 Markdown（粗分类为 text.md 或以标题/围栏/front matter 开头）时才 emit 树
        if (isRoot && looksLikeMarkdown(data, scope.start, scope.end)) {
            let _ = ctx.emit(Span(scope.start, scope.end), TypeId("text.md"), 1.0, HashMap<String, String>())
        }
        // 块级子区域 + 副产物
        for (blk in md.blocks) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            let childType = match (blk.kind) {
                case "frontmatter" => TypeId("text.md.frontmatter")
                case "heading" => TypeId("text.md.heading")
                case "paragraph" => TypeId("text.md.paragraph")
                case "table" => TypeId("text.md.table")
                case "html" => TypeId("markup.html")
                case "code" =>
                    if (blk.param.isEmpty()) {
                        TypeId("text.md.code")
                    } else {
                        let t = TypeId("code.block")
                        let t2 = TypeId("code.block[lang=${blk.param}]")
                        let _ = t
                        t2
                    }
                case _ => TypeId("text.md.paragraph")
            }
            let childSpan = if (blk.kind == "code") {
                blk.codeSpan
            } else if (blk.kind == "frontmatter") {
                blk.contentSpan
            } else {
                blk.span
            }
            let attrs = HashMap<String, String>()
            if (blk.kind == "code" && !blk.param.isEmpty()) {
                attrs["lang"] = blk.param
            }
            if (blk.kind == "frontmatter") {
                attrs["format"] = "yaml"
            }
            if (blk.kind == "code") {
                attrs["content"] = "${blk.codeSpan.start}:${blk.codeSpan.end}"
            }
            let _ = ctx.emit(childSpan, childType, 1.0, attrs)
            // 链接副产物：URL 候选
            for ((_, target) in blk.links) {
                let targetText = String.fromUtf8(data[target.start..target.end])
                if (looksLikeUrlText(targetText)) {
                    ctx.addCandidate(target, TypeId("entity.url"))
                } else if (targetText.contains("@") && !targetText.contains(" ")) {
                    ctx.addCandidate(target, TypeId("entity.email"))
                }
            }
        }
    }
}

// ---------- 实体检测器 ----------

/// URL 检测器：验证候选 + 主动扫描文本。
public class UrlDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("entity.url") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            let b = data[i]
            // http:// https:// ftp:// www.
            if (b == 104 || b == 102 || b == 119) { // h f w
                let isHttp = startsWithAscii(data, i, "http://") || startsWithAscii(data, i, "https://")
                let isFtp = startsWithAscii(data, i, "ftp://")
                let isWww = startsWithAscii(data, i, "www.")
                if (isHttp || isFtp || isWww) {
                    let urlEnd = findUrlEnd(data, i, scope.end)
                    if (urlEnd > i) {
                        // 匹配对不可信输入有界（17）：超过实体长度上限不命中
                        if (urlEnd - i > ctxConfig(ctx).maxEntityLength) {
                            i += 1
                            continue
                        }
                        let sp = Span(i, urlEnd)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 1.0, HashMap<String, String>())
                        }
                        i = urlEnd
                        continue
                    }
                }
            }
            i += 1
        }
    }

    /// URL 结束：空白、引号、右括号（若无匹配左括号）等。
    func findUrlEnd(data: Array<UInt8>, start: Int64, end: Int64): Int64 {
        var i = start
        var parenDepth = 0
        while (i < end) {
            let b = data[i]
            if (b == 32 || b == 9 || b == 10 || b == 13 || b == 34 || b == 39 || b == 60 || b == 62) {
                break
            }
            if (b == 40) { // '('
                parenDepth += 1
            } else if (b == 41) { // ')'
                if (parenDepth == 0) {
                    break
                }
                parenDepth -= 1
            } else if (b == 44 || b == 59) { // ',' ';' 常为句尾标点
                break
            }
            i += 1
        }
        // 去掉句尾点
        while (i > start && (data[i - 1] == 46 || data[i - 1] == 41)) {
            if (data[i - 1] == 41 && parenDepth > 0) {
                break
            }
            i -= 1
        }
        i
    }
}

/// Email 检测器。
public class EmailDetector <: Detector {
    public init() {}

    public prop typeId: TypeId {
        get() { TypeId("entity.email") }
    }

    public prop within: Array<String> {
        get() { [] }
    }

    public prop dependsOn: Array<TypeId> {
        get() { [] }
    }

    public prop authoritative: Array<TypeId> {
        get() { [] }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = readAll(ctx)
        var i = scope.start
        while (i < scope.end) {
            if (ctx.cancelled) {
                ctx.markTruncated()
                return
            }
            if (data[i] == 64) { // '@'
                // 本地向左、域名向右；匹配对不可信输入有界（17）：
                // 向左/向右各最多扫 maxEntityLength 字节
                let cap = ctxConfig(ctx).maxEntityLength
                let lsFloor = if (i - cap > scope.start) { i - cap } else { scope.start }
                let reCeil = if (i + 1 + cap < scope.end) { i + 1 + cap } else { scope.end }
                let ls = findWordStart(data, i, lsFloor)
                let re = findWordEnd(data, i + 1, reCeil)
                if (i > ls && re > i + 1 && re - i - 1 >= 4) {
                    let local = String.fromUtf8(data[ls..i])
                    let domain = String.fromUtf8(data[i + 1..re])
                    if (emailLocalOk(local) && domain.contains(".")) {
                        let sp = Span(ls, re)
                        if (!alreadyCovered(ctx, sp)) {
                            let _ = ctx.emit(sp, typeId, 1.0, HashMap<String, String>())
                        }
                        i = re
                        continue
                    }
                }
            }
            i += 1
        }
    }

    func findWordStart(data: Array<UInt8>, from: Int64, floor: Int64): Int64 {
        var i = from
        while (i > floor) {
            let b = data[i - 1]
            if (isEmailChar(b)) {
                i -= 1
                continue
            }
            break
        }
        i
    }

    func findWordEnd(data: Array<UInt8>, from: Int64, ceil: Int64): Int64 {
        var i = from
        while (i < ceil) {
            let b = data[i]
            if (isEmailChar(b)) {
                i += 1
                continue
            }
            break
        }
        // 去掉结尾点
        while (i > from && data[i - 1] == 46) {
            i -= 1
        }
        i
    }

    func isEmailChar(b: UInt8): Bool {
        (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) ||
        b == 46 || b == 45 || b == 95 || b == 43
    }

    func emailLocalOk(s: String): Bool {
        if (s.isEmpty()) {
            return false
        }
        for (b in s.toArray()) {
            if (!isEmailChar(b)) {
                return false
            }
        }
        true
    }
}

// ---------- 共享辅助 ----------

/// 检测器读取整个输入（有界：依赖输入保留策略）。
public func readAll(ctx: DetectContext): Array<UInt8> {
    ctx.session.inputBytes()
}

/// 从 ctx 取配置（包装：ctx 实现暴露 config）。
public func ctxConfig(ctx: DetectContext): ScanConfig {
    ctx.session.scanConfig()
}

/// 区间是否已被同类型区域覆盖（避免重复 emit）。
/// 不同类型的嵌套是合法的（7：子区域必须被父区域完全包含），不去重。
public func alreadyCovered(ctx: DetectContext, sp: Span): Bool {
    let selfText = ctx.forType.text
    for (r in ctx.session.regionTree.ordered()) {
        if (r.typeId.text == selfText && r.span.contains(sp)) {
            return true
        }
    }
    false
}
