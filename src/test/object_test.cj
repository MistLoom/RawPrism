// 对象模型测试：值类型、路径访问、JSONPath、深度遍历、反查区间、显式复制。
package rawprism.test

import rawprism.core.*
import rawprism.object.*
import rawprism.parse.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func objScalarTypes(): Unit {
    // Number 保留原文（10.2）
    let n = ObjNumber("1.50")
    @Assert(n.rawValue == "1.50")
    @Assert(n.asFloat() == Some(1.5))
    @Assert(n.asText() == Some("1.50"))
    let b = ObjBool(true)
    @Assert(b.asBool() == Some(true))
    let t = ObjText("plain")
    @Assert(t.asText() == Some("plain"))
    let z = ObjNull()
    @Assert(objKindEq(z.kind, ObjKind.KNull))
}

@Test
func objTextEscapesDecodedOnDemand(): Unit {
    // 含转义时按需解码（10.2）
    let t = ObjText("a\\nb", escaped: true)
    @Assert(t.asText() == Some("a\nb"))
    let u = ObjText("a\\u4F60", escaped: true)
    @Assert(u.asText() == Some("a你"))
    let p = ObjText("raw", escaped: false)
    @Assert(p.asText() == Some("raw"))
}

@Test
func objMapDuplicateKeys(): Unit {
    // Mapping 保持源顺序、允许重复键（10.2）
    let m = ObjMap()
    m.put("k", ObjNumber("1"))
    m.put("k", ObjNumber("2"))
    @Assert(m.size() == 2)
    @Assert(m.get("k").getOrThrow().asInt() == Some(1))
    @Assert(m.getAll("k").size == 2)
    @Assert(m.getAll("k")[1].asInt() == Some(2))
}

@Test
func objPathAccess(): Unit {
    let text = "{\"store\": {\"book\": [{\"title\": \"t1\"}, {\"title\": \"t2\"}]}}"
    let r = parseJson(text.toArray())
    let root = r.value.getOrThrow()
    if (let Some(t) <- root.at("store.book.1.title")) {
        @Assert(t.asText() == Some("t2"))
    } else {
        @Assert(false)
    }
    @Assert(root.at("store.book.5.title").isNone())
    @Assert(root.at("no.such.path").isNone())
}

@Test
func jsonPathBasic(): Unit {
    let text = "{\"store\": {\"book\": [{\"title\": \"t1\", \"price\": 10}, {\"title\": \"t2\", \"price\": 20}]}}"
    let root = parseJson(text.toArray()).value.getOrThrow()
    @Assert(jsonPath(root, "$.store.book[*].title").size == 2)
    @Assert(jsonPath(root, "$.store.book[0].title").size == 1)
    @Assert(jsonPath(root, "$.store.book[0,1]").size == 2)
    @Assert(jsonPath(root, "$.store.book[*]").size == 2)
    @Assert(jsonPath(root, "$..price").size == 2)
    @Assert(jsonPath(root, "$.store.book[0:2]").size == 2)
    @Assert(jsonPath(root, "$.store.book[-1:].title").size == 1)
}

@Test
func jsonPathFilter(): Unit {
    let text = "{\"b\": [{\"p\": 5}, {\"p\": 15}, {\"p\": 25}]}"
    let root = parseJson(text.toArray()).value.getOrThrow()
    // [?(@.p > 10)]（RFC 9535 过滤子集）
    let hits = jsonPath(root, "$.b[?(@.p>10)]")
    @Assert(hits.size == 2)
    let eq = jsonPath(root, "$.b[?(@.p==5)]")
    @Assert(eq.size == 1)
    let ex = jsonPath(root, "$.b[?(@.p)]")
    @Assert(ex.size == 3)
}

@Test
func objWalkWithControl(): Unit {
    let text = "{\"a\": {\"b\": 1}, \"c\": 2}"
    let root = parseJson(text.toArray()).value.getOrThrow()
    let visited = CounterBox(0)
    root.walk({ n: Obj =>
        let _ = n
        visited.value += 1
        if (visited.value == 2) {
            return WalkControl.Stop
        }
        WalkControl.Continue
    })
    @Assert(visited.value == 2)
}

@Test
func objSkipSubtree(): Unit {
    let text = "{\"a\": {\"deep\": {\"x\": 1}}, \"b\": 2}"
    let root = parseJson(text.toArray()).value.getOrThrow()
    let count = CounterBox(0)
    root.walk({ n: Obj =>
        let _ = n
        count.value += 1
        if (objKindEq(n.kind, ObjKind.KMap) && count.value == 2) {
            return WalkControl.SkipSubtree
        }
        WalkControl.Continue
    })
    // 根、a（跳过子树）、b
    @Assert(count.value == 3)
}

@Test
func objReverseSpanLookup(): Unit {
    let text = "{\"a\": 1}"
    let r = parseJson(text.toArray())
    let root = r.value.getOrThrow()
    // 由节点反查原文区间（10.4）
    if (let Some(a) <- root.get("a")) {
        @Assert(spanEq(a.sourceSpan(), Span(6, 7)))
    } else {
        @Assert(false)
    }
}

@Test
func objToOwnedIndependent(): Unit {
    let text = "{\"a\": [1, 2]}"
    let root = parseJson(text.toArray()).value.getOrThrow()
    let owned = root.toOwned()
    // 显式复制为不引用输入的独立结构（10.4 / 13.3）
    if (let Some(a) <- owned.get("a")) {
        @Assert(a.items().size == 2)
        @Assert(a.at(0).getOrThrow().asInt() == Some(1))
    } else {
        @Assert(false)
    }
}

@Test
func xmlToObjMapping(): Unit {
    // XML DOM 映射（10.3）：属性、文本、子元素分别以约定键表示；同名子元素聚合
    let text = "<r a=\"1\"><x>1</x><x>2</x><y>t</y></r>"
    let xr = parseXml(text.toArray())
    let obj = xmlToObj(xr.roots[0], None)
    if (let Some(attrs) <- obj.get("#attr")) {
        @Assert(attrs.get("a").getOrThrow().asText() == Some("1"))
    } else {
        @Assert(false)
    }
    if (let Some(y) <- obj.get("y")) {
        // 文本以约定键 #text 表示
        @Assert(y.get("#text").getOrThrow().asText() == Some("t"))
    } else {
        @Assert(false)
    }
    if (let Some(xs) <- obj.get("x")) {
        // 同名子元素聚合为 Sequence
        @Assert(objKindEq(xs.kind, ObjKind.KSeq))
        @Assert(xs.items().size == 2)
    } else {
        @Assert(false)
    }
    // 原始子节点顺序单独保留
    @Assert(obj.get("#order").isSome())
}

@Test
func numberPrecisionPreserved(): Unit {
    // 高精度数字按需解析，保留原文避免精度损失（10.2）
    let n = ObjNumber("123456789012345678901234567890")
    @Assert(n.rawValue == "123456789012345678901234567890")
    // asInt 溢出解析失败时仍可通过原文读取
    @Assert(n.asText() == Some("123456789012345678901234567890"))
}

/// 整数包装（测试辅助）。
public class CounterBox {
    public var value: Int64
    public init(v: Int64) {
        this.value = v
    }
}
