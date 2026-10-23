// 17 待定项：同级重叠区域的查询与确定性优先级、置信度阈值暴露。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func overlappingSiblingsQueryable(): Unit {
    // 7 / 17：同级区域可以重叠；重叠关系可查询（直接对区域树验证）
    let tree = RegionTree()
    let a = Region(Span(0, 20), TypeId("markup.html"), confidence: 1.0)
    let b = Region(Span(10, 30), TypeId("markup.html"), confidence: 0.9)
    let c = Region(Span(40, 50), TypeId("entity.url"), confidence: 1.0)
    tree.addRoot(a)
    tree.addRoot(b)
    tree.addRoot(c)
    // a 与 b 同级重叠，互为对方的唯一同级重叠区域
    let oa = tree.overlapping(a)
    @Assert(oa.size == 1)
    @Assert(spanEq(oa[0].span, b.span) && oa[0].typeName == b.typeName)
    let ob = tree.overlapping(b)
    @Assert(ob.size == 1)
    @Assert(spanEq(ob[0].span, a.span) && ob[0].typeName == a.typeName)
    // c 与任何区域都不重叠
    @Assert(tree.overlapping(c).size == 0)
    // 嵌套（父子）不算同级重叠
    let p = Region(Span(100, 200), TypeId("text.md"))
    let ch = Region(Span(110, 190), TypeId("struct.json"))
    p.children.add(ch)
    tree.addRoot(p)
    @Assert(tree.overlapping(p).size == 0)

    // 会话级：真实语料中重叠查询自洽——返回的都是同层且确实相交的区域
    let s = Session(Input("{\"a\": 1} see https://p.io here"))
    s.scan()
    let urls = s.getAll(["entity.url"])
    let rel = s.regionTree.overlapping(urls[0].region)
    for (r in rel) {
        @Assert(r.span.intersects(urls[0].region.span))
    }
}

@Test
func traversalOrderIsDeterministicPriority(): Unit {
    // 17：优先级规则的当前实现为确定性遍历序——
    // 起点升序；起点相同外层（更长区间）优先；再按 TypeId 字典序
    let text = "run\n# Doc\n\n{\"a\": 1} then https://p.io\n" +
               "```json\n{\"q\": 7}\n```\n<!DOCTYPE html><html><body><p>hi</p></body></html>\n"
    let s = Session(Input(text))
    s.scan()
    let ordered = s.tree.ordered()
    // 全序：逐对比较满足 regionBefore（非降）
    for (i in 1..ordered.size) {
        let a = ordered[i - 1]
        let b = ordered[i]
        let ok = if (a.start != b.start) {
            a.start < b.start
        } else if (a.end != b.end) {
            a.end > b.end
        } else {
            a.typeId.text <= b.typeId.text
        }
        @Assert(ok)
    }
    // 重复扫描同输入，顺序一致（确定性）
    let s2 = Session(Input(text))
    s2.scan()
    let a = s.tree.ordered()
    let b = s2.tree.ordered()
    @Assert(a.size == b.size)
    for (i in 0..a.size) {
        @Assert(spanEq(a[i].span, b[i].span))
        @Assert(a[i].typeId.text == b[i].typeId.text)
    }
}

@Test
func confidenceThresholdExposure(): Unit {
    // 17：置信度阈值经 ScanConfig.confidenceThreshold 对外暴露——
    // 低于阈值的区域不登记；区域上的 confidence 值可读取
    let text = "run\n<!DOCTYPE html><html><body><p>hi</p></body></html>\n"
    // 默认阈值 0：文档级（1.0）与片段级（0.9）都登记
    let s1 = Session(Input(text))
    s1.scan()
    @Assert(s1.getAll(["markup.html"]).size == 2)
    @Assert(s1.getAll(["markup.html"])[0].region.confidence == 1.0)
    @Assert(s1.getAll(["markup.html"])[1].region.confidence == 0.9)

    // 阈值提高到 0.95：0.9 的片段级区域被过滤，1.0 的保留
    var cfg = ScanConfig()
    cfg.confidenceThreshold = 0.95
    let s2 = Session(Input(text), config: cfg)
    s2.scan()
    @Assert(s2.getAll(["markup.html"]).size == 1)
    @Assert(s2.getAll(["markup.html"])[0].region.confidence == 1.0)
}
