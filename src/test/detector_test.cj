// 自定义检测器用法测试（9.4 / 16）：Detector 只需声明 typeId 并实现 detect，
// within/dependsOn/authoritative 走接口默认实现；注册后与内置获取器使用方式相同。
package rawprism.test

import rawprism.*
import rawprism.core.*
import rawprism.object.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 覆写 within，其余可选属性用默认值
public class TicketId <: Getter<String> {
    public prop typeId: TypeId {
        get() {
            TypeId("entity.ticket")
        }
    }

    public prop within: Array<String> {
        get() {
            ["text.*"]
        }
    }

    public func detect(scope: Span, ctx: DetectContext): Unit {
        // 在 scope 内查找并 emit 区域
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

    public func materialize(region: Region, ctx: MaterializeContext): String {
        ctx.text(region.span)
    }
}

// 嵌套获取器形态（9.5）：dependsOn 声明依赖
public class OpenApiDoc <: Getter<Obj> {
    public prop typeId: TypeId {
        get() {
            TypeId("doc.openapi")
        }
    }

    public prop dependsOn: Array<TypeId> {
        get() {
            [TypeId("struct.json")]
        }
    }

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

    public func materialize(region: Region, ctx: MaterializeContext): Obj {
        ctx.objectOf(region)
    }
}

// 只实现必填成员：typeId + detect + materialize，三个可选属性全部沿用接口默认实现
public class BareTicket <: Getter<String> {
    public prop typeId: TypeId {
        get() {
            TypeId("entity.ticket")
        }
    }

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

    public func materialize(region: Region, ctx: MaterializeContext): String {
        ctx.text(region.span)
    }
}

@Test
func detectorOptionalPropsDefaultToEmpty(): Unit {
    // 未覆写的属性取接口默认实现（空数组）
    let b = BareTicket()
    @Assert(b.typeId.text == "entity.ticket")
    @Assert(b.within.size == 0)
    @Assert(b.dependsOn.size == 0)
    @Assert(b.authoritative.size == 0)
}

@Test
func detectorDefaultsStillScanWholeInput(): Unit {
    // within 缺省为空 = 整个输入（5.2），不覆写也能命中
    let reg = GetterRegistry()
    @Assert(reg.register(BareTicket()))
    let s = Session(Input("id TKT-1234 end TKT-99"), registry: Some(reg))
    s.scan()
    let hits = s.getAll(["entity.ticket"])
    @Assert(hits.size == 2)
    @Assert(hits[0].text() == "TKT-1234")
}

@Test
func detectorOverriddenPropsAreVisible(): Unit {
    // 覆写的属性可被注册表与调度器使用
    let t = TicketId()
    @Assert(t.typeId.text == "entity.ticket")
    @Assert(t.within.size == 1)
    @Assert(t.within[0] == "text.*")
    @Assert(t.dependsOn.size == 0)
    @Assert(t.authoritative.size == 0)
    let d = OpenApiDoc()
    @Assert(d.dependsOn.size == 1)
    @Assert(d.dependsOn[0].text == "struct.json")
    @Assert(d.within.size == 0)
    @Assert(d.authoritative.size == 0)
}

@Test
func customDetectorRegisteredAndScanned(): Unit {
    // 注册后的自定义获取器与内置获取器使用方式相同（9.4）
    let reg = GetterRegistry()
    @Assert(reg.register(TicketId()))
    let s = Session(Input("id TKT-1234 end TKT-99"), registry: Some(reg))
    s.scan()
    let hits = s.getAll(["entity.ticket"])
    @Assert(hits.size == 2)
    @Assert(hits[0].text() == "TKT-1234")
    @Assert(hits[1].text() == "TKT-99")
    // 类型计数中出现自定义类型
    var found = false
    for ((t, _) in s.typeCounts()) {
        if (t == "entity.ticket") {
            found = true
        }
    }
    @Assert(found)
}

@Test
func nestedGetterDependencyOrdersExecution(): Unit {
    // 嵌套获取器（9.5）：dependsOn 决定执行顺序，注册即用
    let reg = GetterRegistry()
    @Assert(reg.register(OpenApiDoc()))
    @Assert(reg.register(JsonDetector()))
    // 依赖排序：struct.json 先于 doc.openapi
    var jsonIdx = -1
    var docIdx = -1
    var i = 0
    for (d in reg.ordered()) {
        if (d.typeId.text == "struct.json") {
            jsonIdx = i
        }
        if (d.typeId.text == "doc.openapi") {
            docIdx = i
        }
        i += 1
    }
    @Assert(jsonIdx >= 0 && docIdx >= 0)
    @Assert(jsonIdx < docIdx)
    let s = Session(Input("{\"openapi\": \"3.0.0\", \"info\": {}}"), registry: Some(reg))
    s.scan()
    let docs = s.getAll(["doc.openapi"])
    @Assert(docs.size == 1)
    if (let Some(v) <- docs[0].value().get("openapi")) {
        @Assert(v.asText() == Some("3.0.0"))
    } else {
        @Assert(false)
    }
}

@Test
func withinSelectorFiltersScheduling(): Unit {
    // within = ["text.*"]：调度器只在匹配的父区域内运行（5.2）
    let reg = GetterRegistry()
    @Assert(reg.register(TicketId()))
    // 纯文本：粗分类 text.plain，within 匹配 text.*
    let s = Session(Input("see TKT-7 at desk"), registry: Some(reg))
    s.scan()
    @Assert(s.getAll(["entity.ticket"]).size == 1)
}
