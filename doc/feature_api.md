# RawPrism API 接口文档

本文档描述 RawPrism 库的全部公开 API。包结构：`rawprism`（会话与检测器）、`rawprism.core`（数据契约与输入）、`rawprism.object`（对象视图与 JSONPath）。

另有 `rawprism.parse`（各格式解析器实现）与 `rawprism.test`（测试）两个包：前者随库发布但不属于稳定接口，内容应经 `Session` / `Obj` 获取，不保证跨版本兼容。

## 1 快速上手

```cangjie
import rawprism.*
import rawprism.core.*
import rawprism.object.*

main() {
    let text =
        "# note\n" +
        "{ \"name\": \"RawPrism\", \"tags\": [\"cangjie\", \"scan\"] }\n" +
        "https://example.com/docs\n"
    let session = Session(Input(text))
    session.scan()

    // 按类型取出 JSON 区域，派生 Object 视图
    let docs = session.getAll(["struct.json"])
    for (got in docs) {
        let obj = got.value()
        if (let Some(name) <- obj.get("name")) {
            if (let Some(s) <- name.asText()) {
                println(s)
            }
        }
    }

    // JSONPath（RFC 9535）
    if (docs.size > 0) {
        let hits = jsonPath(docs[0].value(), "$.tags[*]")
        println(hits.size)
    }

    // 实体
    println(session.getAll(["entity.url"]).size)
}
```

---

## 2 rawprism 包（会话与获取）

### Session

会话：对一个输入的扫描状态容器，持有区域树、类型标记和物化缓存。

```
/*
* 构造会话
* 参数input-输入（Input 的三种构造之一）
* 参数config-扫描配置，缺省 ScanConfig()
* 参数registry-获取器注册表，缺省使用内置注册表 defaultRegistry()
*/
public class Session {
    public init(input: Input, config!: ScanConfig = ScanConfig(),
                registry!: Option<GetterRegistry> = None)

    public let input: Input                 // 输入
    public let config: ScanConfig           // 扫描配置
    public let registry: GetterRegistry     // 注册表
    public let tree: RegionTree             // 区域树
    public let marks: HashMap<String, TypeMark>  // 类型标记
    public var truncated: Bool              // 截断标记（C7）

    /// 执行扫描：粗分类 + 按依赖序细分类。幂等：已覆盖区间不重扫。返回自身。
    public func scan(): Session

    /// 通用获取：按类型选择器取区域结果。选择器支持精确/前缀/通配/子类型/参数限定。
    public func getAll(selectors: Array<String>): ArrayList<RegionResult>

    /// 第一个匹配结果，可能不存在。
    public func first(selectors: Array<String>): ?RegionResult

    /// 某类型已登记的区域（触发该类型按需扫描）。
    public func regionsOf(typeIdText: String): ArrayList<Region>

    /// 列出输入中出现的类型及数量（按类型名字典序）。
    public func typeCounts(): ArrayList<(String, Int64)>

    /// 混合类型遍历：按位置顺序遍历全部区域；回调返回 WalkControl 控制。
    public func walk(visitor: (Region, Int64) -> WalkControl): Unit

    /// 点查询：包含某偏移的区域链（外层在前）。
    public func chainAt(offset: Int64): ArrayList<Region>

    /// 区间查询：与某区间相交的全部区域。
    public func intersecting(s: Span): ArrayList<Region>

    /// 区域的对象视图（惰性物化并缓存，C6）。
    public func objectOf(region: Region): Obj

    /// 粗分类结果（顶层区域类型）。
    public func coarseRootType(): TypeId

    /// 获取类型标记（不存在则创建）。
    public func markOf(typeIdText: String): TypeMark

    /// 请求某类型在某区间上的结果（类型标记获取流程）。
    public func requestType(t: TypeId, scope: Span): Unit

    /// 共享预扫描：同一 key 在一次输入上只计算一次，之后直接命中缓存。
    public func prescan<T>(key: String, compute: () -> T): T

    /// 换行位置共享预扫描。
    public func lineStartsShared(): ArrayList<Int64>

    /// 物化上下文。
    public func materializeCtx(): MaterializeContext

    /// 时间预算 / 取消检查。
    public func budgetExceeded(): Bool

    /// 请求取消的原子标志。
    public let cancelFlag: AtomicBool

    // 输入保留状态报告
    public func retainedBytes(): Int64      // 当前驻留内存的字节数
    public func droppedSpans(): ArrayList<Span>  // 因保留上限丢弃、不可再物化的区间
    public func fullyRetained(): Bool        // 输入是否仍完整可物化

    // SessionLike 只读视图实现
    public prop regionTree: RegionTree
    public func inputBytes(): Array<UInt8>
    public func scanConfig(): ScanConfig
}
```

### RegionResult

区域结果：区域信息 + 惰性的值。只读取区域信息不触发物化。

```
public class RegionResult {
    public init(region: Region, session: Session)

    public let region: Region           // 区域
    public prop typeId: TypeId          // 区域类型
    public prop span: Span              // 区间

    /// 原文文本（惰性物化）。
    public func text(): String

    /// 对象视图（惰性物化；仅树形类型 struct.* / markup.html / code.block 有意义）。
    public func value(): Obj
}
```

### Detector / Getter / 上下文接口

```
/// 检测器：实现者必须声明 typeId 并实现 detect，其余属性有默认实现。
public interface Detector {
    prop typeId: TypeId                 // 产出的主类型（必填）
    prop within: Array<String>          // 可运行的父区域选择器，默认 []（整个输入）
    prop dependsOn: Array<TypeId>       // 需要先完成的类型，默认 []
    prop authoritative: Array<TypeId>   // 具有权威性的类型，默认 []
    func detect(scope: Span, ctx: DetectContext): Unit
}

/// 获取器：面向用户的接口，声明所需类型并物化结果。
public interface Getter<T> <: Detector {
    func materialize(region: Region, ctx: MaterializeContext): T
}

/// 检测上下文：读取输入、产出区域、登记副产物。
public interface DetectContext {
    prop forType: TypeId
    func byteAt(offset: Int64): Int64               // -1 表示不可用
    func text(span: Span): String
    prop available: Int64
    func emit(span: Span, typeId: TypeId, confidence: Float64,
              attributes: HashMap<String, String>): Region
    func addCandidate(span: Span, typeId: TypeId): Unit          // 副产物候选登记
    func emitAuthoritative(span: Span, typeId: TypeId, confidence: Float64): Region
    func addNegative(span: Span): Unit
    func addError(span: Span): Unit
    func markTruncated(): Unit
    prop cancelled: Bool
    func lineStarts(): ArrayList<Int64>
    prop session: SessionLike                       // 供嵌套获取器读取其他类型结果
}

/// 会话只读视图（嵌套获取器用）。
public interface SessionLike {
    func regionsOf(typeIdText: String): ArrayList<Region>
    prop regionTree: RegionTree
    func inputBytes(): Array<UInt8>
    func scanConfig(): ScanConfig
    func objectOf(region: Region): Obj
}

/// 物化上下文。
public interface MaterializeContext {
    func text(span: Span): String
    func objectOf(region: Region): Obj
    func withinBudget(size: Int64): Bool
}
```

### GetterRegistry

```
/// 获取器注册表：按 dependsOn 拓扑排序，拒绝循环依赖。
public class GetterRegistry {
    public init()

    /// 注册检测器。返回是否成功（重复注册同类型幂等返回 true；循环依赖返回 false）。
    public func register(d: Detector): Bool

    /// 依赖拓扑排序；存在循环依赖时返回 false。
    public func topoSort(): Bool

    /// 拓扑排序后的检测器列表。
    public func ordered(): Array<Detector>

    /// 找到产出某类型的检测器。
    public func detectorFor(typeIdText: String): Option<Detector>
}

/// 默认注册表：全部内置检测器（JSON/NDJSON/YAML/TOML/CSV/XML/HTML/Markdown/URL/Email）。
public func defaultRegistry(): GetterRegistry
```

### 内置获取器与检测器

```
/// 单类型获取器基类：按类型获取并物化。
public abstract class TypedGetter<T> {
    public func all(): ArrayList<RegionResult>                    // 全部该类型结果
    public func allWithin(parentSelector: String): ArrayList<RegionResult>  // 限定父区域
    public func first(): ?RegionResult                            // 第一个结果
}

public class JsonDoc <: TypedGetter<Obj>      // struct.json
public class HtmlDoc <: TypedGetter<Obj>      // markup.html
public class UrlEntity <: TypedGetter<String> // entity.url
public class EmailEntity <: TypedGetter<String> // entity.email

// 内置检测器（默认注册表已含；可单独注册到自定义注册表）
public class JsonDetector <: Detector
public class NdjsonDetector <: Detector
public class YamlDetector <: Detector
public class TomlDetector <: Detector
public class CsvDetector <: Detector
public class XmlDetector <: Detector
public class HtmlDetector <: Detector
public class MarkdownDetector <: Detector
public class UrlDetector <: Detector
public class EmailDetector <: Detector
```

### 并发

```
/// 异步扫描入口：返回 Future，由调用方决定何时等待。
public func scanAsync(input: Input, config!: ScanConfig = ScanConfig(),
                      registry!: Option<GetterRegistry> = None): Future<Session>

/// 并行扫描：独立检测器类型按 config.parallelism 调度，结果与串行一致。
public func scanConcurrent(session: Session): Session

/// 请求取消：线程内通过 ctx.cancelled / session.budgetExceeded() 响应。
public func cancelScan(session: Session): Unit

/// 线程安全的按需扫描入口（同一类型同一区间并发只触发一次检测）。
public func requestTypeThreadSafe(session: Session, t: TypeId): Unit
```

### 粗分类辅助（公开）

```
/// HTML 文档形状判断（<!doctype html> / <html 开头）。
public func looksLikeHtmlDocument(data: Array<UInt8>, start: Int64, end: Int64): Bool

/// Markdown 形状判断（front matter / 标题 / 围栏代码块）。
public func looksLikeMarkdown(data: Array<UInt8>, start: Int64, end: Int64): Bool
```

---

## 3 rawprism.core 包（数据契约与输入）

### Span

```
/// [start, end) 偏移区间，相对整个输入起点，单位为 UTF-8 字节。
public struct Span {
    public init(start: Int64, end: Int64)
    public let start: Int64
    public let end: Int64
    public prop length: Int64
    public func contains(offset: Int64): Bool
    public func contains(other: Span): Bool
    public func intersects(other: Span): Bool
    public func isEmpty(): Bool
}

/// Span 相等判断（结构体不支持 ==）。
public func spanEq(a: Span, b: Span): Bool
```

### TypeId

日常使用无需直接构造 `TypeId`：`getAll` / `first` / `regionsOf` 等接口接收的都是普通字符串选择器（如 `"struct.json"`、`"text.*"`）。`TypeId` 是这些字符串的解析后表示，仅在编写自定义检测器（声明 `typeId`）或调用底层 `requestType` 时才需显式构造。

```
/// 层级化类型标识：`struct.json`、`markup.html#text`、`code.block[lang=json]`。
public struct TypeId {
    public init(raw: String)
    public let parts: Array<String>
    public let sub: Option<String>
    public let params: HashMap<String, String>

    public prop text: String            // 完整规范字符串
    public prop category: String        // 顶层类别（struct / markup / text / entity / code / …）
    public func isWildcard(): Bool

    /// 本类型是否匹配选择器。选择器支持：
    /// 精确名 struct.json；前缀 text.md；通配 text.*；
    /// 子类型限定 markup.html#text；参数限定 code.block[lang=json]。
    public func matches(selector: String): Bool
    public func matchesAny(selectors: Array<String>): Bool
    public static func parse(raw: String): TypeId
}
```

### Region / RegionTree

```
/// 区域：分类结果的基本单元。已发布区域只追加、不修改（支持并发读取）。
public class Region {
    public init(span: Span, typeId: TypeId, confidence!: Float64 = 1.0,
                attributes!: HashMap<String, String> = HashMap<String, String>())
    public let span: Span
    public let typeId: TypeId
    public let confidence: Float64
    public let attributes: HashMap<String, String>
    public let children: ArrayList<Region>
    public var complete: Bool           // 是否已闭合（分段输入）
    public var truncated: Bool          // 因资源上限被截断
    public var errored: Bool            // 该区间检测出错
    public prop start: Int64
    public prop end: Int64
    public prop typeName: String
    public func contains(offset: Int64): Bool
}

/// 区域树：按包含关系组织。遍历序：位置升序；起点相同外层优先；再按 TypeId 字典序。
public class RegionTree {
    public let roots: ArrayList<Region>
    public func addRoot(region: Region): Unit
    public func ordered(): ArrayList<Region>                    // 全树遍历序
    public func chainAt(offset: Int64): ArrayList<Region>       // 点查询
    public func intersecting(s: Span): ArrayList<Region>        // 区间查询
    public func bySelectors(selectors: Array<String>): ArrayList<Region>  // 选择器查询
    public func overlapping(region: Region): ArrayList<Region>  // 同级重叠查询
    public func sortedLike(list: ArrayList<Region>): ArrayList<Region>  // 按遍历序排序副本
    public func size(): Int64
}
```

### TypeMark

```
/// 类型标记：单个类型在某会话中的扫描状态。
public class TypeMark {
    public init(typeIdText: String)
    public let typeIdText: String
    public let covered: ArrayList<Span>     // 已覆盖区间（无论是否命中）
    public let regions: ArrayList<Region>   // 已登记区域
    public let candidates: ArrayList<Span>  // 候选区间（他人登记、未验证）
    public let negatives: ArrayList<Span>   // 否定区间
    public let errors: ArrayList<Span>      // 错误区间
    public var status: MarkStatus           // Unscanned / Partial / Done

    public func addCovered(s: Span): Unit
    public func addCandidate(s: Span): Unit
    public func addNegative(s: Span): Unit
    public func addError(s: Span): Unit
    public func uncovered(want: Span): ArrayList<Span>   // 未覆盖部分
    public func candidatesIn(s: Span): ArrayList<Span>   // 与 s 相交的候选
}

public enum MarkStatus { | Unscanned | Partial | Done }
```

### Input / ChunkSource

```
/// 会话输入：逻辑上连续的一段文本。只读（C1），副本须显式 toBytes/toText。
public class Input {
    public init(text: String, policy!: UTF8Policy = UTF8Policy.ErrorRegion)      // 参数输入
    public init(bytes: Array<UInt8>, policy!: UTF8Policy = UTF8Policy.ErrorRegion)
    public init(source: ChunkSource, retentionLimit!: Int64 = -1,
                policy!: UTF8Policy = UTF8Policy.ErrorRegion)                    // 分段输入
    public static func fromFile(path: String, chunkSize!: Int64 = 65536,
                                retentionLimit!: Int64 = -1,
                                policy!: UTF8Policy = UTF8Policy.ErrorRegion): Input  // 大文件输入

    public let retentionLimit: Int64      // 保留上限，-1 表示不限制
    public prop available: Int64            // 逻辑输入终点（全局偏移）
    public func text(s: Span): String       // 取区间文本；不可物化时抛 MaterializeUnavailableException
    public func byteAt(offset: Int64): Int64
    public func hasMore(): Bool             // 分段输入：是否还有数据
    public func pullNext(): Bool            // 按需拉取下一段
    public func pullUntil(reach: Int64): Unit
    public func canMaterialize(s: Span): Bool
    public func isDropped(s: Span): Bool
    public func retainedBytes(): Int64
    public func droppedSpans(): ArrayList<Span>
    public func fullyRetained(): Bool
    public func invalidUtf8Spans(): ArrayList<Span>
    public func toBytes(): Array<UInt8>     // 显式独立副本
    public func toText(): String
    public var finished: Bool
}

/// 分段来源：按顺序产出文本分段，边界可落在任意位置；不支持回退。
public interface ChunkSource {
    func next(): ?Array<UInt8>
}

public class StringChunkSource <: ChunkSource {
    public init(chunks: Array<String>)
    public init(bytes: Array<Array<UInt8>>)
}

public class FileChunkSource <: ChunkSource {
    public init(path: String, chunkSize!: Int64 = 65536)
    public func readRange(s: Span): Array<UInt8>   // 可重读来源按区间重读
}

/// 非法 UTF-8 处理策略。
public enum UTF8Policy { | Strict | ErrorRegion }

/// 校验 UTF-8，返回全部非法字节区间（有序、不重叠）。
public func validateUtf8(data: Array<UInt8>): ArrayList<Span>

/// 物化不可用异常：分段数据超出保留上限时报告（4.4.6）。
public class MaterializeUnavailableException <: Exception {
    public init(span: Span, message: String)
    public let span: Span
}
```

### ScanConfig / ParseLimits

```
/// 扫描配置：资源上限（C7）、并发度、时间预算、错误策略。
public class ScanConfig {
    public init()
    public var maxDepth: Int64               // 嵌套深度上限，默认 256
    public var maxStructureLength: Int64     // 单个结构最大长度，默认 16MiB
    public var maxRegions: Int64             // 区域数量上限，默认 100000
    public var maxMaterializeBytes: Int64    // 单次物化上限，默认 64MiB
    public var parallelism: Int64            // 并行度上限，默认 1（串行）
    public var timeBudgetMs: Int64           // 时间预算（毫秒），默认 0（不限）
    public var utf8Policy: UTF8Policy        // 非法 UTF-8 策略
    public var truncateOnDepth: Bool         // 深度超限截断而非失败，默认 true
    public var confidenceThreshold: Float64  // 置信度阈值，默认 0.0
    public var maxEntityLength: Int64        // 实体匹配长度上限，默认 2048
}

/// 解析配置。
public class ParseLimits {
    public init(maxDepth!: Int64 = 256, maxStructureLength!: Int64 = 16 * 1024 * 1024,
                truncateOnDepth!: Bool = true)
}
```

---

## 4 rawprism.object 包（统一对象视图）

### Obj

```
/// 树形值节点（抽象类）。来源：JSON、YAML、XML/HTML DOM、CSV、TOML、front matter。
/// 默认是引用输入的视图，不复制原文；节点记录来源区间与源格式标签。
public abstract class Obj {
    public let kind: ObjKind                    // KNull / KBool / KNumber / KText / KSeq / KMap
    public var span: Span                       // 来源原文区间
    public var formatTag: String                // 源格式标签，如 "json"、"html:element:div"
    public var truncated: Bool                  // 结构因资源上限被截断

    public func rawText(): String               // 引用区间取原文文本
    public func asText(): ?String               // 按需解码文本值
    public func asInt(): ?Int64
    public func asFloat(): ?Float64
    public func asBool(): ?Bool
    public func items(): ArrayList<Obj>         // 序列元素（仅 KSeq）
    public func entries(): ArrayList<(String, Obj)>  // 键值序列（仅 KMap，保持源顺序、允许重复键）
    public func get(key: String): ?Obj          // 按键取值（返回首个匹配）
    public func getAll(key: String): ArrayList<Obj>  // 按键取全部值（重复键）
    public func at(index: Int64): ?Obj          // 按下标取值（仅 KSeq）
    public func at(path: String): ?Obj          // 点分路径访问，如 "a.b.0"
    public func enumerate(): ArrayList<(String, Obj)>
    public func walk(visitor: (Obj) -> WalkControl): Bool  // 带控制深度遍历
    public func sourceSpan(): Span              // 由节点反查原文区间
    public func toOwned(): Obj                  // 显式复制为不引用输入的独立结构
}

public enum ObjKind { | KNull | KBool | KNumber | KText | KSeq | KMap }
public enum WalkControl { | Continue | SkipSubtree | Stop }

// 具体值类
public class ObjNull <: Obj
public class ObjBool <: Obj
public class ObjNumber <: Obj      // 保留原文，按需解析，避免精度损失
public class ObjText <: Obj        // 原文区间；含转义时按需解码
public class ObjSeq <: Obj
public class ObjMap <: Obj

// 枚举比较辅助（仓颉枚举不支持 ==）
public func objKindEq(a: ObjKind, b: ObjKind): Bool
public func walkCtrlEq(a: WalkControl, b: WalkControl): Bool

// 工具函数
public func parseInt64(s: String): ?Int64
public func parseFloat64(s: String): ?Float64
public func decodeEscapes(s: String, formatTag: String): String
public func xmlUnescape(s: String): String
```

### JSONPath

```
/// 对象视图上的 JSONPath 查询（RFC 9535），返回全部命中节点。
/// 支持：$ . .. [] [n] [m:n:s] * 等标准片段。
public func jsonPath(root: Obj, query: String): ArrayList<Obj>
```

---

## 5 自定义检测器与获取器

实现 `Detector` / `Getter<T>`：只需声明 `typeId` 并实现 `detect`（`Getter` 另需 `materialize`）；`within` / `dependsOn` / `authoritative` 已由接口提供默认实现（空数组），仅在需要时覆写。

```
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
        // ...命中时：
        // let _ = ctx.emit(Span(i, e), typeId, 1.0, HashMap<String, String>())
    }
    public func materialize(region: Region, ctx: MaterializeContext): String {
        ctx.text(region.span)
    }
}

// 注册即用，与内置获取器相同
let reg = GetterRegistry()
reg.register(TicketId())
let s = Session(Input("id TKT-1234 end"), registry: Some(reg))
s.scan()
let hits = s.getAll(["entity.ticket"])
```

| 属性 | 类型 | 默认实现 | 说明 |
|------|------|----------|------|
| `typeId` | TypeId | （必填） | 产出的主类型 |
| `within` | Array\<String\> | `[]`（整个输入） | 可运行的父区域选择器 |
| `dependsOn` | Array\<TypeId\> | `[]` | 需要先完成的类型 |
| `authoritative` | Array\<TypeId\> | `[]` | 具有权威性的类型 |

嵌套获取器（依赖其他类型结果）示例：

```
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
        for (r in ctx.session.regionsOf("struct.json")) {
            if (ctx.session.objectOf(r).get("openapi").isSome()) {
                let _ = ctx.emit(r.span, typeId, 1.0, HashMap<String, String>())
            }
        }
    }
    public func materialize(region: Region, ctx: MaterializeContext): Obj {
        ctx.objectOf(region)
    }
}
```

注册表按 `dependsOn` 拓扑排序保证执行顺序，并拒绝循环依赖。
