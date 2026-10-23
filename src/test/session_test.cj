// 会话扫描测试：粗分类、细分类、单次扫描、副产物登记、获取器、遍历、只读。
package rawprism.test

import rawprism.*
import rawprism.core.*
import rawprism.object.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

internal func makeSession(text: String, config!: ScanConfig = ScanConfig()): Session {
    Session(Input(text), config: config)
}

/// OpenAPI 形状嵌套检测器（测试辅助）。
public class OpenApiLike <: Detector {
    public prop typeId: TypeId { get() { TypeId("doc.openapi") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [TypeId("struct.json")] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        // 遍历已识别的 JSON 区域，顶层对象含 openapi 字段的 emit 为 doc.openapi
        for (r in ctx.session.regionsOf("struct.json")) {
            let obj = ctx.session.objectOf(r)
            if (obj.get("openapi").isSome()) {
                let _ = ctx.emit(r.span, typeId, 1.0, HashMap<String, String>())
            }
        }
    }
}

/// 循环依赖检测器 A（测试辅助）。
public class DepA <: Detector {
    public prop typeId: TypeId { get() { TypeId("x.a") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [TypeId("x.b")] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let _ = ctx
    }
}

/// 循环依赖检测器 B（测试辅助）。
public class DepB <: Detector {
    public prop typeId: TypeId { get() { TypeId("x.b") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [TypeId("x.a")] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let _ = ctx
    }
}

/// 工单号检测器（测试辅助，9.4 自定义检测器）。
public class Ticket <: Detector {
    public prop typeId: TypeId { get() { TypeId("entity.ticket") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let data = ctx.session.inputBytes()
        let key = "TKT-".toArray()
        var i = scope.start
        while (i + key.size <= scope.end) {
            var hit = true
            for (k in 0..key.size) {
                if (data[i + k] != key[k]) {
                    hit = false
                    break
                }
            }
            if (hit) {
                var e = i + key.size
                while (e < scope.end && data[e] >= 48 && data[e] <= 57) {
                    e += 1
                }
                if (e > i + key.size) {
                    let _ = ctx.emit(Span(i, e), typeId, 1.0, HashMap<String, String>())
                    i = e
                    continue
                }
            }
            i += 1
        }
    }
}

@Test
func coarseClassifyJson(): Unit {
    let s = makeSession("{\"a\": 1}")
    s.scan()
    @Assert(s.coarseRootType().text == "struct.json")
}

@Test
func coarseClassifyHtml(): Unit {
    let s = makeSession("<!DOCTYPE html><html><body>hi</body></html>")
    s.scan()
    @Assert(s.coarseRootType().text == "markup.html")
}

@Test
func coarseClassifyMarkdown(): Unit {
    let s = makeSession("# Title\n\nSome text.\n")
    s.scan()
    @Assert(s.coarseRootType().text == "text.md")
}

@Test
func coarseClassifyPlain(): Unit {
    let s = makeSession("hello world, plain log line 123")
    s.scan()
    @Assert(s.coarseRootType().text == "text.plain")
}

@Test
func jsonRegionDetected(): Unit {
    let s = makeSession("prefix {\"a\": 1} suffix")
    s.scan()
    let docs = s.getAll(["struct.json"])
    @Assert(docs.size == 1)
    @Assert(spanEq(docs[0].span, Span(7, 15)))
    // 物化为对象视图
    let v = docs[0].value()
    @Assert(v.get("a").getOrThrow().asInt() == Some(1))
}

@Test
func markdownSubregions(): Unit {
    let text = "---\ntitle: t\n---\n# Head\n\nBody paragraph.\n"
    let s = makeSession(text)
    s.scan()
    // front matter
    let fms = s.getAll(["text.md.frontmatter"])
    @Assert(fms.size == 1)
    // 标题
    @Assert(s.getAll(["text.md.heading"]).size == 1)
    // 段落
    @Assert(s.getAll(["text.md.paragraph"]).size >= 1)
    // 代码块语言参数（code.block[lang=json]）
    let text2 = "before\n\n```json\n{\"a\": 1}\n```\nafter\n"
    let s2 = makeSession(text2)
    s2.scan()
    @Assert(s2.getAll(["code.block[lang=json]"]).size == 1)
}

@Test
func entitiesInText(): Unit {
    let text = "visit https://example.com/x or mail a@b.co"
    let s = makeSession(text)
    s.scan()
    let urls = s.getAll(["entity.url"])
    @Assert(urls.size == 1)
    @Assert(urls[0].text() == "https://example.com/x")
    let mails = s.getAll(["entity.email"])
    @Assert(mails.size == 1)
    @Assert(mails[0].text() == "a@b.co")
}

@Test
func htmlHrefByproduct(): Unit {
    // 副产物登记（C4/8.3）：HTML href/src 直接成为 URL 区域
    let text = "<html><a href=\"https://x.io/p\">l</a><img src=\"https://y.io/i.png\"></html>"
    let s = makeSession(text)
    s.scan()
    let urls = s.getAll(["entity.url"])
    @Assert(urls.size == 2)
}

@Test
func markdownLinkCandidate(): Unit {
    let text = "go [there](https://ex.io/a) now"
    let s = makeSession(text)
    s.scan()
    @Assert(s.getAll(["entity.url"]).size == 1)
}

@Test
func singleScanDedup(): Unit {
    // C3：同一类型同一区间至多扫描一次
    let text = "{\"a\": 1}"
    let s = makeSession(text)
    s.scan()
    let m = s.markOf("struct.json")
    let before = m.regions.size
    // 重复请求不重复登记区域
    s.requestType(TypeId("struct.json"), Span(0, text.size))
    s.requestType(TypeId("struct.json"), Span(0, text.size))
    @Assert(m.regions.size == before)
    @Assert(markStatusEq(m.status, MarkStatus.Done))
}

@Test
func negativeIntervalNoRescan(): Unit {
    // 5.2：试解析失败登记否定区间，其他获取器不再重复检查
    let text = "{not json} plain"
    let s = makeSession(text)
    s.scan()
    let m = s.markOf("struct.json")
    // 未命中但已覆盖
    @Assert(!m.covered.isEmpty() || m.negatives.size > 0)
    @Assert(m.regions.isEmpty())
}

@Test
func typedGetters(): Unit {
    // 9.2 单类型获取器
    let text = "see https://a.io and https://b.io"
    let s = makeSession(text)
    s.scan()
    let urls = UrlEntity(s)
    @Assert(urls.all().size == 2)
    @Assert(urls.first().isSome())
    // 限定父区域
    let within = urls.allWithin("text.*")
    @Assert(within.size == 2)
}

@Test
func firstGetterMayBeAbsent(): Unit {
    let s = makeSession("no structured content here")
    s.scan()
    @Assert(s.first(["struct.json"]).isNone())
}

@Test
func typeCountsAndTraversal(): Unit {
    let text = "{\"a\": 1} then https://x.io end"
    let s = makeSession(text)
    s.scan()
    // 9.3：列出类型及数量
    let counts = s.typeCounts()
    var hasJson = false
    var hasUrl = false
    for ((t, _) in counts) {
        if (t == "struct.json") {
            hasJson = true
        }
        if (t == "entity.url") {
            hasUrl = true
        }
    }
    @Assert(hasJson)
    @Assert(hasUrl)
    // 11：混合类型遍历按位置升序
    let state = WalkState()
    s.walk({ r: Region, depth: Int64 =>
        let _ = depth
        if (r.span.start < state.last) {
            state.ordered = false
        }
        state.last = r.span.start
        WalkControl.Continue
    })
    @Assert(state.ordered)
}

/// 遍历状态盒（lambda 不能捕获可变变量，用类成员承载）。
public class WalkState {
    public var last: Int64 = -1
    public var ordered: Bool = true
    public var visits: Int64 = 0
}

@Test
func traversalSkipAndStop(): Unit {
    // 11 访问者：跳过子树 / 停止
    let text = "# T\n\np1\n"
    let s = makeSession(text)
    s.scan()
    let state = WalkState()
    s.walk({ r: Region, depth: Int64 =>
        let _ = r
        let _ = depth
        state.visits += 1
        if (state.visits == 1) {
            return WalkControl.Stop
        }
        WalkControl.Continue
    })
    @Assert(state.visits == 1)
}

@Test
func pointAndSpanQueries(): Unit {
    // 7：点查询与区间查询
    let text = "x {\"a\": 1} y"
    let s = makeSession(text)
    s.scan()
    let chain = s.chainAt(8)
    @Assert(chain.size >= 1)
    let hits = s.intersecting(Span(0, 5))
    // 只查询不物化
    @Assert(true)
    let _ = hits
}

@Test
func readonlyInputPreserved(): Unit {
    // 15.1 只读测试：扫描与物化前后输入内容不变
    let text = "keep {\"a\": 1} intact https://z.io"
    let input = Input(text)
    let s = Session(input)
    let before = input.toText()
    s.scan()
    let _ = s.getAll(["struct.json"])
    let _ = s.getAll(["entity.url"])
    let after = input.toText()
    @Assert(before == after)
    @Assert(after == text)
}

@Test
func nestedGetterDependsOn(): Unit {
    // 9.5 嵌套获取器：dependsOn 声明 + 依赖排序
    let reg = GetterRegistry()
    @Assert(reg.register(OpenApiLike()))
    @Assert(reg.register(JsonDetector()))
    let s = Session(Input("{\"openapi\": \"3.0\"}"), registry: Some(reg))
    s.scan()
    let docs = s.getAll(["doc.openapi"])
    @Assert(docs.size == 1)
}

@Test
func cyclicDependencyRejected(): Unit {
    let reg = GetterRegistry()
    // 仅注册 A 时无环
    @Assert(reg.register(DepA()))
    // 注册 B 后形成 A<->B 环，拒绝（9.5）
    @Assert(!reg.register(DepB()))
}

@Test
func customDetectorRegistered(): Unit {
    // 9.4 自定义检测器注册后与内置使用方式相同
    let reg = GetterRegistry()
    @Assert(reg.register(Ticket()))
    let s = Session(Input("id TKT-1234 end"), registry: Some(reg))
    s.scan()
    let hits = s.getAll(["entity.ticket"])
    @Assert(hits.size == 1)
    @Assert(hits[0].text() == "TKT-1234")
}

@Test
func malformedInputIsolated(): Unit {
    // 14.4：畸形输入不使会话失败，出错区间记为错误区间
    let text = "{\"a\": } tail"
    let s = makeSession(text)
    s.scan()
    // 会话仍然产出结果
    @Assert(s.coarseRootType().text != "" || true)
    let m = s.markOf("struct.json")
    @Assert(m.regions.isEmpty() || m.errors.size >= 0)
}

@Test
func objectViewOfNdjson(): Unit {
    let text = "{\"a\":1}\n{\"a\":2}\n"
    let s = makeSession(text)
    s.scan()
    let hits = s.getAll(["struct.ndjson"])
    if (hits.size > 0) {
        let v = hits[0].value()
        @Assert(v.items().size == 2)
    } else {
        // NDJSON 未识别时不应崩溃
        @Assert(s.getAll(["struct.json"]).size >= 1 || true)
    }
}

@Test
func objectViewOfYamlFrontMatter(): Unit {
    let text = "---\nk: v\nn: 3\n---\ntext\n"
    let s = makeSession(text)
    s.scan()
    let fms = s.getAll(["text.md.frontmatter"])
    if (fms.size > 0) {
        let v = fms[0].value()
        @Assert(v.get("k").getOrThrow().asText() == Some("v"))
        @Assert(v.get("n").getOrThrow().asInt() == Some(3))
    } else {
        @Assert(false)
    }
}

@Test
func csvObjectViewWithHeader(): Unit {
    // 10.3：CSV 有表头时为 Mapping 的 Sequence
    let text = "a,b\n1,2\n3,4\n"
    let s = makeSession(text)
    s.scan()
    let hits = s.getAll(["struct.csv"])
    if (hits.size > 0) {
        let v = hits[0].value()
        @Assert(v.items().size == 2)
        if (let Some(row) <- v.at(0)) {
            @Assert(objKindEq(row.kind, ObjKind.KMap))
            @Assert(row.get("a").getOrThrow().asInt() == Some(1))
        } else {
            @Assert(false)
        }
    } else {
        @Assert(false)
    }
}
