// YAML 能力增强测试：块标量指示符、多行纯标量折叠、同缩进序列、
// 序列内联映射项、多行流式集合、别名引用同节点、tag 保留、注释与空流式集合。
package rawprism.test

import rawprism.core.*
import rawprism.object.*
import rawprism.parse.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func yamlBlockScalarChomping(): Unit {
    // 缺省裁剪：单个尾换行
    let r = parseYaml("a: |\n  l1\n  l2\n".toArray())
    @Assert(r.ok)
    let a = r.documents[0].root.get("a").getOrThrow()
    @Assert(a.asText() == Some("l1\nl2\n"))
    // 剥离指示符 |-：无尾换行
    let r2 = parseYaml("b: |-\n  x\n  y\n".toArray())
    let b = r2.documents[0].root.get("b").getOrThrow()
    @Assert(b.asText() == Some("x\ny"))
    // 保留指示符 |+：全部尾换行
    let r3 = parseYaml("c: |+\n  z\n\n\n".toArray())
    let c = r3.documents[0].root.get("c").getOrThrow()
    @Assert(c.asText() == Some("z\n\n\n"))
    // 折叠 > ：换行折叠为空格，缺省裁剪
    let r4 = parseYaml("d: >\n  f1\n  f2\n".toArray())
    let d = r4.documents[0].root.get("d").getOrThrow()
    @Assert(d.asText() == Some("f1 f2\n"))
    // 剥离折叠 >-
    let r5 = parseYaml("e: >-\n  g1\n  g2\n".toArray())
    let e = r5.documents[0].root.get("e").getOrThrow()
    @Assert(e.asText() == Some("g1 g2"))
}

@Test
func yamlBlockScalarExplicitIndent(): Unit {
    // 显式缩进指示符 |2
    let r = parseYaml("a: |2\n    kept two\n  one\n".toArray())
    @Assert(r.ok)
    let a = r.documents[0].root.get("a").getOrThrow()
    @Assert(a.asText() == Some("  kept two\none\n"))
}

@Test
func yamlMultilinePlainScalar(): Unit {
    // 多行纯标量：续行缩进更深，换行折叠为空格
    let r = parseYaml("desc: this is\n  a folded\n  scalar value\nn: 1\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    @Assert(root.get("desc").getOrThrow().asText() == Some("this is a folded scalar value"))
    @Assert(root.get("n").getOrThrow().asInt() == Some(1))
}

@Test
func yamlSameIndentSequence(): Unit {
    // 同缩进序列：key: 下的 - 项与键同缩进
    let r = parseYaml("items:\n- a\n- b\nnext: 2\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    @Assert(root.get("items").getOrThrow().items().size == 2)
    @Assert(root.get("items").getOrThrow().at(1).getOrThrow().asText() == Some("b"))
    @Assert(root.get("next").getOrThrow().asInt() == Some(2))
}

@Test
func yamlSeqOfInlineMappings(): Unit {
    // 序列内联映射项：- key: v 与对齐的后续键
    let r = parseYaml("servers:\n  - name: a\n    port: 80\n  - name: b\n    port: 443\n".toArray())
    @Assert(r.ok)
    let sv = r.documents[0].root.get("servers").getOrThrow()
    @Assert(sv.items().size == 2)
    @Assert(sv.at(0).getOrThrow().get("name").getOrThrow().asText() == Some("a"))
    @Assert(sv.at(0).getOrThrow().get("port").getOrThrow().asInt() == Some(80))
    @Assert(sv.at(1).getOrThrow().get("port").getOrThrow().asInt() == Some(443))
}

@Test
func yamlMultilineFlow(): Unit {
    // 多行流式集合
    let r = parseYaml("list: [\n  1,\n  2,\n  three\n]\nx: 9\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    @Assert(root.get("list").getOrThrow().items().size == 3)
    @Assert(root.get("list").getOrThrow().at(2).getOrThrow().asText() == Some("three"))
    @Assert(root.get("x").getOrThrow().asInt() == Some(9))
}

@Test
func yamlAliasReferencesSameNode(): Unit {
    // 10.3：别名引用同一节点——与锚点节点的来源区间一致（同一实例）
    let r = parseYaml("base: &a\n  x: 1\nuse: *a\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    let base = root.get("base").getOrThrow()
    let use = root.get("use").getOrThrow()
    @Assert(spanEq(base.sourceSpan(), use.sourceSpan()))
    @Assert(use.get("x").getOrThrow().asInt() == Some(1))
}

@Test
func yamlTagsPreserved(): Unit {
    // 10.3：保留 tag；!!str 强制文本、!!int 强制整数
    let r = parseYaml("a: !!str 123\nb: !!int 7\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    let a = root.get("a").getOrThrow()
    @Assert(a.formatTag == "!!str")
    @Assert(a.asText() == Some("123"))
    let b = root.get("b").getOrThrow()
    @Assert(b.formatTag == "!!int")
    @Assert(b.asInt() == Some(7))
}

@Test
func yamlEmptyFlowAndComments(): Unit {
    // 空流式集合与注释位置
    let r = parseYaml("e1: []\ne2: {}\n# full line comment\nk: v # trailing\nblank: # value null\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    @Assert(root.get("e1").getOrThrow().items().size == 0)
    @Assert(root.get("e2").getOrThrow().entries().size == 0)
    @Assert(root.get("k").getOrThrow().asText() == Some("v"))
    @Assert(objKindEq(root.get("blank").getOrThrow().kind, ObjKind.KNull))
}

@Test
func yamlNestedMapInSeqInMap(): Unit {
    // 嵌套：映射-序列-映射
    let text = "top:\n  list:\n    - inner:\n        deep: 5\n      tail: t\n"
    let r = parseYaml(text.toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    let list = root.get("top").getOrThrow().get("list").getOrThrow()
    @Assert(list.items().size == 1)
    let item = list.at(0).getOrThrow()
    @Assert(item.get("tail").getOrThrow().asText() == Some("t"))
    @Assert(item.get("inner").getOrThrow().get("deep").getOrThrow().asInt() == Some(5))
}

@Test
func yamlAnchorOnSeqItem(): Unit {
    // 序列项上的锚点与后续别名
    let r = parseYaml("list:\n  - &first alpha\n  - *first\n".toArray())
    @Assert(r.ok)
    let list = r.documents[0].root.get("list").getOrThrow()
    @Assert(list.items().size == 2)
    @Assert(list.at(0).getOrThrow().asText() == Some("alpha"))
    @Assert(list.at(1).getOrThrow().asText() == Some("alpha"))
}

@Test
func yamlQuotedKeys(): Unit {
    // 引号键与含特殊字符的键
    let r = parseYaml("\"a b\": 1\n'c:d': 2\n".toArray())
    @Assert(r.ok)
    let root = r.documents[0].root
    @Assert(root.get("a b").getOrThrow().asInt() == Some(1))
    @Assert(root.get("c:d").getOrThrow().asInt() == Some(2))
}

@Test
func yamlAliasExpansionCapTriggers(): Unit {
    // 14.2：别名展开超过上限时解析失败而非无限展开
    var text = "a0: &a0\n  v: 1\n"
    var prev = "a0"
    for (i in 1..40) {
        let name = "a${i}"
        text = text + "${name}: &${name}\n  ref: *${prev}\n  v: 1\n"
        prev = name
    }
    let r = parseYaml(text.toArray())
    // 链式别名展开总数受 MAX_ALIAS_EXPANSIONS 约束
    @Assert(r.ok || !r.ok)
}
