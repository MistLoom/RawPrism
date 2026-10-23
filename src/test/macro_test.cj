// @Detector 属性宏用法测试（9.4 / 16）：宏注入 Detector 接口的四个属性，
// 注册后的自定义获取器与内置获取器使用方式相同。
package rawprism.test

import rawprism.*
import rawprism.core.*
import rawprism.object.*
import rawprism.macros.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 9.4 示例形态：宏生成 typeId / within / dependsOn / authoritative 四个属性
@Detector[typeId = "entity.ticket", within = ["text.*"]]
public class TicketId <: Getter<String> {
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
@Detector[typeId = "doc.openapi", dependsOn = ["struct.json"]]
public class OpenApiDoc <: Getter<Obj> {
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

@Test
func detectorMacroInjectsProps(): Unit {
    // 宏注入的四个属性可被注册表与调度器使用
    let t = TicketId()
    @Assert(t.typeId.text == "entity.ticket")
    @Assert(t.within.size == 1)
    @Assert(t.within[0] == "text.*")
    @Assert(t.dependsOn.size == 0)
    @Assert(t.authoritative.size == 0)
}

@Test
func detectorMacroWithinArrayAndDeps(): Unit {
    let d = OpenApiDoc()
    @Assert(d.typeId.text == "doc.openapi")
    @Assert(d.dependsOn.size == 1)
    @Assert(d.dependsOn[0].text == "struct.json")
    // 未声明的属性缺省为空
    @Assert(d.within.size == 0)
    @Assert(d.authoritative.size == 0)
}

@Test
func detectorMacroRegisteredAndScanned(): Unit {
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
func detectorMacroNestedGetter(): Unit {
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
func detectorMacroWithinFiltersScheduling(): Unit {
    // within = ["text.*"]：调度器只在匹配的父区域内运行（5.2）
    let reg = GetterRegistry()
    @Assert(reg.register(TicketId()))
    // 纯文本：粗分类 text.plain，within 匹配 text.*
    let s = Session(Input("see TKT-7 at desk"), registry: Some(reg))
    s.scan()
    @Assert(s.getAll(["entity.ticket"]).size == 1)
}
