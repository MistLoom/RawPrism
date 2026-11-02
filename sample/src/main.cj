// RawPrism 使用示例：扫描 → 分类 → 区域树 → Object/JSONPath → 自定义检测器。
// 运行：cd sample && cjpm run
// 依赖：cjpm.toml 中 rawprism（path=".."）与 rawprism_macros（path="../macros"）
package rawprism_sample

import rawprism.*
import rawprism.core.*
import rawprism.object.*
import rawprism_macros.*
import std.collection.*
import std.fs.{Path, exists}

// 自定义实体检测器：工单号 TKT-<digits>。
// 用 @Detector 宏注入 Detector 的 typeId/within/dependsOn/authoritative 四个属性，
// 只实现 detect 与 materialize 即可（对应 doc/feature_api.md 第 5 节）。
@Detector[typeId = "entity.ticket", within = ["text.*"]]
public class TicketId <: Getter<String> {
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

// 混合输入：Markdown front matter + 围栏 JSON + URL + 邮箱 + 工单号。
func demoText(): String {
    "---\n" +
        "title: Release Note\n" +
        "author: team@example.com\n" +
        "---\n" +
        "# RawPrism Demo\n\n" +
        "Config payload:\n" +
        "```json\n" +
        "{ \"name\": \"RawPrism\", \"tags\": [\"cangjie\", \"scan\"], \"site\": \"https://example.com/docs\" }\n" +
        "```\n\n" +
        "Contact support@example.com or file a ticket TKT-1234.\n" +
        "See https://rawprism.dev/home for details.\n"
}

// 打印某选择器的全部命中区域。
func printRegions(session: Session, selectors: Array<String>, label: String): Unit {
    let items = session.getAll(selectors)
    println("  ${label} (${items.size}):")
    for (it in items) {
        println("    - \"${oneLine(it.text())}\"  @ [${it.span.start}, ${it.span.end})")
    }
}

// 把多行文本压成单行便于展示。
func oneLine(s: String): String {
    let flat = StringBuilder()
    for (ch in s.toRuneArray()) {
        if (ch == '\n' || ch == '\r') {
            flat.append(" ")
        } else {
            flat.append(ch)
        }
    }
    let out = flat.toString()
    if (out.size > 60) {
        return out[0..60] + "..."
    }
    out
}

// 内联文本演示：一次给出整段输入。
func demoInMemory(): Unit {
    println("【示例 1】内联文本输入")

    // 1) 注册表：内置检测器 + 自定义工单检测器
    let reg = defaultRegistry()
    let _ = reg.register(TicketId())

    // 2) 会话扫描（输入只读，结果均为区间引用）
    let session = Session(Input(demoText()), registry: Some(reg))
    session.scan()

    // 3) 类型清单
    println("== 类型清单 ==")
    for ((t, c) in session.typeCounts()) {
        println("  ${t}: ${c}")
    }

    // 4) 区域树遍历（按位置顺序，深度缩进）
    println("\n== 区域树 ==")
    session.walk((r, depth) => {
        for (_ in 0..depth) {
            print("  ")
        }
        println("[${r.span.start}, ${r.span.end}) ${r.typeName}")
        WalkControl.Continue
    })

    // 5) 结构化提取：JSON 区域派生统一 Object，字段访问 + JSONPath
    println("\n== JSON 提取（struct.json -> Object）==")
    let docs = session.getAll(["struct.json"])
    if (docs.size > 0) {
        let obj = docs[0].value()
        if (let Some(name) <- obj.get("name")) {
            if (let Some(s) <- name.asText()) {
                println("  name = ${s}")
            }
        }
        let tags = jsonPath(obj, "$.tags[*]")
        println("  tags via JSONPath $.tags[*] (${tags.size}):")
        for (t in tags) {
            if (let Some(s) <- t.asText()) {
                println("    - ${s}")
            }
        }
    } else {
        println("  （未命中 struct.json 区域）")
    }

    // 6) 实体提取：URL / 邮箱（内置）+ 工单号（自定义）
    println("\n== 实体提取 ==")
    printRegions(session, ["entity.url"], "entity.url")
    printRegions(session, ["entity.email"], "entity.email")
    printRegions(session, ["entity.ticket"], "entity.ticket")

    // 7) front matter 派生 Object（按其内部 YAML 映射）
    println("\n== front matter（text.md.frontmatter -> Object）==")
    let fm = session.getAll(["text.md.frontmatter"])
    if (fm.size > 0) {
        let o = fm[0].value()
        for ((k, v) in o.entries()) {
            let disp = match (v.asText()) {
                case Some(s) => s
                case None => "<${v.formatTag}>"
            }
            println("  ${k} = ${disp}")
        }
    } else {
        println("  （未命中 front matter 区域）")
    }
}

// 大文件输入演示：按分段读取，物化时按区间引用（相同内容结果一致）。
func demoFromFile(path: String): Unit {
    println("\n【示例 2】大文件输入（Input.fromFile）")
    if (!exists(Path(path))) {
        println("  跳过：未找到 ${path}")
        return
    }
    let input = Input.fromFile(path, chunkSize: 4096)
    while (input.hasMore()) {} // 顺序拉取全部分段
    let session = Session(input)
    session.scan()
    println("  驻留字节: ${session.retainedBytes()}，输入完整可物化: ${session.fullyRetained()}")
    println("  类型清单:")
    for ((t, c) in session.typeCounts()) {
        println("    ${t}: ${c}")
    }
}

main(): Int64 {
    println("========================================")
    println("  RawPrism 使用示例")
    println("========================================\n")

    demoInMemory()
    demoFromFile("sample/data/mixed.md")

    println("\n示例结束。")
    0
}
