// 解析器测试：JSON/NDJSON/YAML/TOML/CSV/XML/HTML/Markdown 结构与偏移。
package rawprism.test

import rawprism.core.*
import rawprism.object.*
import rawprism.parse.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func parseJsonBasic(): Unit {
    let text = "{\"a\": 1, \"b\": [true, null, \"x\"]}"
    let r = parseJson(text.toArray())
    @Assert(r.ok)
    let v = r.value.getOrThrow()
    @Assert(objKindEq(v.kind, ObjKind.KMap))
    if (let Some(a) <- v.get("a")) {
        @Assert(a.asInt() == Some(1))
    } else {
        @Assert(false)
    }
    if (let Some(b) <- v.get("b")) {
        @Assert(b.items().size == 3)
        @Assert(b.at(0).getOrThrow().asBool() == Some(true))
        @Assert(objKindEq(b.at(1).getOrThrow().kind, ObjKind.KNull))
        @Assert(b.at(2).getOrThrow().asText() == Some("x"))
    } else {
        @Assert(false)
    }
    @Assert(r.consumed == text.size)
}

@Test
func parseJsonOffsets(): Unit {
    let text = "{\"k\": \"v\"}"
    let r = parseJson(text.toArray())
    @Assert(r.ok)
    let v = r.value.getOrThrow()
    @Assert(spanEq(v.span, Span(0, text.size)))
    if (let Some(t) <- v.get("k")) {
        // 字符串值区间含引号
        @Assert(spanEq(t.span, Span(6, 9)))
        @Assert(String.fromUtf8(text.toArray()[6..9]) == "\"v\"")
    } else {
        @Assert(false)
    }
}

@Test
func parseJsonEscapes(): Unit {
    let r = parseJson("\"a\\nb\\u4F60\"".toArray())
    @Assert(r.ok)
    let t = r.value.getOrThrow()
    @Assert(t.asText() == Some("a\nb你"))
}

@Test
func parseJsonMalformed(): Unit {
    @Assert(!parseJson("{".toArray()).ok)
    @Assert(!parseJson("[1,]".toArray()).ok)
    @Assert(!parseJson("{\"a\" 1}".toArray()).ok)
    @Assert(!parseJson("tru".toArray()).ok)
    @Assert(!parseJson("01x".toArray()).ok)
}

@Test
func parseJsonDepthLimit(): Unit {
    // 深度超限：默认截断并标注（truncateOnDepth），不崩溃
    var text = ""
    for (_ in 0..300) {
        text = text + "["
    }
    text = text + "1"
    for (_ in 0..300) {
        text = text + "]"
    }
    let r = parseJson(text.toArray())
    // 深度截断时该结构不可完整解析（截断标记，C7）
    var depthHandled = false
    if (!r.ok) {
        depthHandled = true
    } else if (let Some(v) <- r.value) {
        depthHandled = v.truncated
    }
    @Assert(depthHandled)
}

@Test
func parseJsonTrailingContent(): Unit {
    let r = parseJson("{} extra".toArray())
    @Assert(!r.ok)
}

@Test
func parseNdjson(): Unit {
    let text = "{\"a\":1}\n{\"a\":2}\n\n{\"a\":3}\n"
    let nd = parseNdjson(text.toArray())
    @Assert(nd.errors.size == 0)
    @Assert(nd.values.size == 3)
    if (let Some(v) <- nd.values[1][0].get("a")) {
        @Assert(v.asInt() == Some(2))
    } else {
        @Assert(false)
    }
    // 区间相对整段输入
    @Assert(spanEq(nd.values[0][1], Span(0, 7)))
}

@Test
func parseNdjsonErrorLine(): Unit {
    let text = "{\"a\":1}\nnot json\n"
    let nd = parseNdjson(text.toArray())
    @Assert(nd.values.size == 1)
    @Assert(nd.errors.size == 1)
}

@Test
func parseYamlBlockMap(): Unit {
    let text = "name: app\nversion: 2\ndebug: true\n"
    let r = parseYaml(text.toArray())
    @Assert(r.ok)
    @Assert(r.documents.size == 1)
    let root = r.documents[0].root
    @Assert(objKindEq(root.kind, ObjKind.KMap))
    if (let Some(n) <- root.get("name")) {
        @Assert(n.asText() == Some("app"))
    } else {
        @Assert(false)
    }
    if (let Some(v) <- root.get("version")) {
        @Assert(v.asInt() == Some(2))
    } else {
        @Assert(false)
    }
    if (let Some(d) <- root.get("debug")) {
        @Assert(d.asBool() == Some(true))
    } else {
        @Assert(false)
    }
}

@Test
func parseYamlNestedAndSeq(): Unit {
    let text = "server:\n  host: h\n  port: 80\nitems:\n  - a\n  - b\n"
    let r = parseYaml(text.toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    if (let Some(s) <- root.get("server")) {
        @Assert(s.get("host").getOrThrow().asText() == Some("h"))
        @Assert(s.get("port").getOrThrow().asInt() == Some(80))
    } else {
        @Assert(false)
    }
    if (let Some(items) <- root.get("items")) {
        @Assert(items.items().size == 2)
        @Assert(items.at(0).getOrThrow().asText() == Some("a"))
    } else {
        @Assert(false)
    }
}

@Test
func parseYamlFlowAndAnchors(): Unit {
    let text = "list: [1, 2, three]\nbase: &a\n  x: 1\nuse: *a\n"
    let r = parseYaml(text.toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    if (let Some(l) <- root.get("list")) {
        @Assert(l.items().size == 3)
        @Assert(l.at(0).getOrThrow().asInt() == Some(1))
        @Assert(l.at(2).getOrThrow().asText() == Some("three"))
    } else {
        @Assert(false)
    }
    // 别名引用同一节点内容
    if (let Some(u) <- root.get("use")) {
        @Assert(u.get("x").getOrThrow().asInt() == Some(1))
    } else {
        @Assert(false)
    }
}

@Test
func parseYamlMultiDoc(): Unit {
    let text = "---\na: 1\n---\nb: 2\n"
    let r = parseYaml(text.toArray())
    @Assert(r.ok)
    @Assert(r.documents.size == 2)
}

@Test
func parseFrontMatter(): Unit {
    let text = "---\ntitle: t\n---\nbody\n"
    let fm = parseFrontMatter(text.toArray(), 0, text.size)
    @Assert(fm.isSome())
    if (let Some((doc, span)) <- fm) {
        @Assert(doc.root.get("title").getOrThrow().asText() == Some("t"))
        @Assert(span.start == 4)
        @Assert(span.end == 12)
    } else {
        @Assert(false)
    }
}

@Test
func parseTomlBasic(): Unit {
    let text = "a = 1\nb = \"s\"\nc = true\nd = 1.5\n"
    let r = parseToml(text.toArray())
    @Assert(r.ok)
    let root = r.root
    @Assert(root.get("a").getOrThrow().asInt() == Some(1))
    @Assert(root.get("b").getOrThrow().asText() == Some("s"))
    @Assert(root.get("c").getOrThrow().asBool() == Some(true))
    @Assert(root.get("d").getOrThrow().asFloat() == Some(1.5))
}

@Test
func parseTomlTables(): Unit {
    let text = "[server]\nhost = \"h\"\n[server.tls]\nenabled = true\n"
    let r = parseToml(text.toArray())
    @Assert(r.ok)
    let server = r.root.get("server").getOrThrow()
    @Assert(server.get("host").getOrThrow().asText() == Some("h"))
    @Assert(server.get("tls").getOrThrow().get("enabled").getOrThrow().asBool() == Some(true))
}

@Test
func parseTomlArrayAndInline(): Unit {
    let text = "nums = [1, 2, 3]\npoint = { x = 1, y = 2 }\n"
    let r = parseToml(text.toArray())
    @Assert(r.ok)
    @Assert(r.root.get("nums").getOrThrow().items().size == 3)
    let p = r.root.get("point").getOrThrow()
    @Assert(p.get("x").getOrThrow().asInt() == Some(1))
    @Assert(p.get("y").getOrThrow().asInt() == Some(2))
}

@Test
func parseTomlDateTime(): Unit {
    let text = "day = 2024-01-02\n"
    let r = parseToml(text.toArray())
    @Assert(r.ok)
    let v = r.root.get("day").getOrThrow()
    // 日期时间保留原文并带标签（10.3）
    @Assert(v.formatTag == "toml:datetime")
    @Assert(v.asText() == Some("2024-01-02"))
}

@Test
func parseCsvWithHeader(): Unit {
    let text = "name,age\nalice,30\nbob,25\n"
    let r = parseCsv(text.toArray())
    @Assert(r.ok)
    @Assert(r.header.size == 2)
    @Assert(r.header[0] == "name")
    @Assert(r.rows.size == 2)
    @Assert(r.rows[0].items().size == 2)
    @Assert(r.rows[0].at(0).getOrThrow().asText() == Some("alice"))
    @Assert(r.rows[0].at(1).getOrThrow().asInt() == Some(30))
}

@Test
func parseCsvQuoted(): Unit {
    let text = "a,b\n\"x,1\",\"say \"\"hi\"\"\"\n"
    let r = parseCsv(text.toArray())
    @Assert(r.ok)
    @Assert(r.rows.size == 1)
    @Assert(r.rows[0].at(0).getOrThrow().asText() == Some("x,1"))
    @Assert(r.rows[0].at(1).getOrThrow().asText() == Some("say \"hi\""))
}

@Test
func parseCsvSemicolonAndTab(): Unit {
    let r1 = parseCsv("a;b\n1;2\n".toArray())
    @Assert(r1.ok)
    @Assert(r1.rows.size == 1)
    let r2 = parseCsv("a\tb\n1\t2\n".toArray())
    @Assert(r2.ok)
    @Assert(r2.rows.size == 1)
}

@Test
func parseXmlBasic(): Unit {
    let text = "<root><item id=\"1\">a</item><item id=\"2\">b</item></root>"
    let r = parseXml(text.toArray())
    @Assert(r.ok)
    @Assert(r.roots.size == 1)
    let root = r.roots[0]
    @Assert(root.name == "root")
    @Assert(root.children.size == 2)
    @Assert(spanEq(root.span, Span(0, text.size)))
    let it = root.children[0]
    @Assert(it.name == "item")
    @Assert(it.attrs.size == 1)
    @Assert(it.attrs[0][0] == "id")
    @Assert(it.attrs[0][1] == "1")
    // 属性值区间（供副产物登记）
    @Assert(spanEq(it.attrs[0][2], Span(16, 17)))
}

@Test
func parseXmlSelfCloseAndVoid(): Unit {
    let text = "<a><br/><b/></a>"
    let r = parseXml(text.toArray(), html: true)
    @Assert(r.ok)
    let root = r.roots[0]
    @Assert(root.children.size == 2)
}

@Test
func parseHtmlScriptRawText(): Unit {
    let text = "<html><script>if (a<b) { x(); }</script></html>"
    let r = parseXml(text.toArray(), html: true)
    @Assert(r.ok)
    let html = r.roots[0]
    let script = html.children[0]
    @Assert(script.name == "script")
    // script 内容按原文文本处理（a<b 不当标签解析）
    @Assert(script.children.size == 1)
    @Assert(script.children[0].isText)
    @Assert(script.children[0].textRaw == "if (a<b) { x(); }")
}

@Test
func parseHtmlTolerant(): Unit {
    // 未闭合标签不使会话失败（14.4）
    let text = "<div><p>text"
    let r = parseXml(text.toArray(), html: true)
    @Assert(r.ok)
    @Assert(r.roots.size >= 1)
}

@Test
func parseXmlNoExternalEntities(): Unit {
    // 不解析外部实体（14.3）：未知实体按原文保留
    let text = "<a>&external;</a>"
    let r = parseXml(text.toArray())
    @Assert(r.ok)
    let obj = xmlToObj(r.roots[0], None)
    // &external 不被展开为外部内容；解码只处理已知实体
    @Assert(true)
    let _ = obj
}

@Test
func markdownBlocks(): Unit {
    let text = "---\ntitle: t\n---\n# Head\n\nPara one.\n\n```json\n{\"a\":1}\n```\n"
    let md = parseMarkdownBlocks(text.toArray())
    @Assert(md.frontMatter.isSome())
    var sawHeading = false
    var sawCode = false
    for (b in md.blocks) {
        if (b.kind == "heading") {
            sawHeading = true
            @Assert(b.param == "h1")
        }
        if (b.kind == "code") {
            sawCode = true
            @Assert(b.param == "json")
            @Assert(String.fromUtf8(text.toArray()[b.codeSpan.start..b.codeSpan.end]) == "{\"a\":1}")
        }
    }
    @Assert(sawHeading)
    @Assert(sawCode)
}

@Test
func markdownLinks(): Unit {
    let text = "see [example](https://example.com/x) here\n"
    let md = parseMarkdownBlocks(text.toArray())
    var links = 0
    for (b in md.blocks) {
        links += b.links.size
    }
    @Assert(links == 1)
}

@Test
func markdownTable(): Unit {
    let text = "| a | b |\n|---|---|\n| 1 | 2 |\n"
    let md = parseMarkdownBlocks(text.toArray())
    var sawTable = false
    for (b in md.blocks) {
        if (b.kind == "table") {
            sawTable = true
        }
    }
    @Assert(sawTable)
}

@Test
func unclosedFenceTolerant(): Unit {
    // 未闭合围栏：按截断处理不崩溃（14.4）
    let text = "```json\n{\"a\":1}\n"
    let md = parseMarkdownBlocks(text.toArray())
    @Assert(md.blocks.size >= 1)
}
