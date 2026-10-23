// 核心类型测试：Span、TypeId 选择器匹配、类型标记覆盖区间计算。
package rawprism.test

import rawprism.core.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func spanBasics(): Unit {
    let s = Span(2, 10)
    @Assert(s.length == 8)
    @Assert(s.contains(2))
    @Assert(!s.contains(10))
    @Assert(s.contains(Span(3, 9)))
    @Assert(!s.contains(Span(1, 9)))
    @Assert(s.intersects(Span(9, 12)))
    @Assert(!s.intersects(Span(10, 12)))
    @Assert(s.intersects(Span(0, 3)))
    @Assert(!s.intersects(Span(0, 2)))
    @Assert(!s.isEmpty())
    @Assert(Span(5, 5).isEmpty())
}

@Test
func typeIdParsing(): Unit {
    let t1 = TypeId("struct.json")
    @Assert(t1.text == "struct.json")
    @Assert(t1.category == "struct")
    @Assert(t1.parts.size == 2)

    let t2 = TypeId("markup.html#text")
    @Assert(t2.text == "markup.html#text")
    @Assert(t2.sub == Some("text"))

    let t3 = TypeId("code.block[lang=json]")
    @Assert(t3.text == "code.block")
    @Assert(t3.params.get("lang") == Some("json"))
}

@Test
func typeIdSelectorMatching(): Unit {
    @Assert(TypeId("text.md.paragraph").matches("text.md"))
    @Assert(TypeId("text.md.paragraph").matches("text"))
    @Assert(TypeId("text.md.paragraph").matches("text.*"))
    @Assert(TypeId("text.md.paragraph").matches("text.md.paragraph"))
    @Assert(!TypeId("text.md.paragraph").matches("text.md.paragraph.extra"))
    @Assert(!TypeId("struct.json").matches("text.*"))

    @Assert(TypeId("markup.html#text").matches("markup.html#text"))
    @Assert(!TypeId("markup.html").matches("markup.html#text"))
    @Assert(!TypeId("markup.html#script").matches("markup.html#text"))

    @Assert(TypeId("code.block[lang=json]").matches("code.block[lang=json]"))
    @Assert(!TypeId("code.block[lang=yaml]").matches("code.block[lang=json]"))
    @Assert(TypeId("entity.url").matches("entity.url"))

    @Assert(TypeId("text.md").matchesAny(["struct.json", "text.*"]))
    @Assert(!TypeId("struct.json").matchesAny(["text.*"]))
}

@Test
func typeMarkUncovered(): Unit {
    let m = TypeMark("struct.json")
    m.addCovered(Span(0, 10))
    m.addCovered(Span(20, 30))
    // 已覆盖部分不再需要扫描
    let rest = m.uncovered(Span(0, 40))
    @Assert(rest.size == 2)
    @Assert(rest[0].start == 10 && rest[0].end == 20)
    @Assert(rest[1].start == 30 && rest[1].end == 40)
    // 完全覆盖时无剩余
    m.addCovered(Span(10, 40))
    @Assert(m.uncovered(Span(0, 40)).isEmpty())
}

@Test
func typeMarkMergeAdjacent(): Unit {
    let m = TypeMark("t")
    m.addCovered(Span(0, 5))
    m.addCovered(Span(5, 10))
    @Assert(m.covered.size == 1)
    @Assert(m.covered[0].start == 0 && m.covered[0].end == 10)
    m.addCovered(Span(20, 25))
    m.addCovered(Span(12, 18))
    @Assert(m.covered.size == 3)
}

@Test
func utf8Validation(): Unit {
    // 合法 ASCII
    @Assert(validateUtf8("hello".toArray()).size == 0)
    // 合法多字节：中文
    @Assert(validateUtf8("你好".toArray()).size == 0)
    // 合法四字节：emoji
    @Assert(validateUtf8("😀".toArray()).size == 0)
    // 非法：孤立续字节 0x80
    var bad: Array<UInt8> = [0x61, 0x80, 0x62]
    let r = validateUtf8(bad)
    @Assert(r.size == 1)
    @Assert(r[0].start == 1 && r[0].end == 2)
    // 非法：截断的多字节序列
    bad = [0xE4, 0xBD]
    @Assert(validateUtf8(bad).size == 1)
    // 非法：过长编码 0xC0
    bad = [0xC0, 0x80]
    @Assert(validateUtf8(bad).size >= 1)
}

/// MarkStatus 相等判断（枚举不支持 ==）。
public func markStatusEq(a: MarkStatus, b: MarkStatus): Bool {
    match (a) {
        case MarkStatus.Unscanned => match (b) { case MarkStatus.Unscanned => true; case _ => false }
        case MarkStatus.Partial => match (b) { case MarkStatus.Partial => true; case _ => false }
        case MarkStatus.Done => match (b) { case MarkStatus.Done => true; case _ => false }
    }
}
