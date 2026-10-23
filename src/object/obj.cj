// 对象模型：统一的树形值视图（第 10 节）。
// 来源：JSON、YAML、XML/HTML DOM、CSV、TOML、front matter。
// 默认是引用输入的视图（区间引用），显式复制为独立结构由 toOwned 完成。
package rawprism.object

import rawprism.core.*
import std.collection.*

/// 值类别（10.2）。
public enum ObjKind {
    | KNull
    | KBool
    | KNumber
    | KText
    | KSeq
    | KMap
}

/// 深度遍历控制。
public enum WalkControl {
    | Continue
    | SkipSubtree
    | Stop
}

/// 树形值节点。所有节点都记录来源区间和源格式标签（10.2 末条）。
public abstract class Obj {
    public let kind: ObjKind
    /// 来源原文区间（相对输入起点）。解析器在结构闭合时回填终值。
    public var span: Span
    /// 源格式标签，例如 "json"、"yaml"、"xml"、"html:element:div"、"toml:datetime"。
    public var formatTag: String
    /// 原文引用（视图默认指向输入；toOwned 后为 None）。
    internal let inputRef: Option<Input>
    /// 结构因资源上限被截断（C7）。
    public var truncated: Bool = false

    public init(kind: ObjKind, span: Span, formatTag: String, inputRef: Option<Input>) {
        this.kind = kind
        this.span = span
        this.formatTag = formatTag
        this.inputRef = inputRef
    }

    /// 原文文本（引用输入的视图按区间取原文；独立副本直接返回已物化的内容）。
    public func rawText(): String {
        if (let Some(inp) <- inputRef) {
            return inp.text(span)
        }
        ""
    }

    /// 按需解码的文本值：Text 直接解码转义；Number/Bool 转字符串；其他返回 None。
    open public func asText(): ?String {
        None
    }

    open public func asInt(): ?Int64 {
        None
    }

    open public func asFloat(): ?Float64 {
        None
    }

    open public func asBool(): ?Bool {
        None
    }

    /// 序列元素（仅 KSeq）。
    open public func items(): ArrayList<Obj> {
        ArrayList<Obj>()
    }

    /// 映射键值序列（仅 KMap，保持源顺序、允许重复键）。
    open public func entries(): ArrayList<(String, Obj)> {
        ArrayList<(String, Obj)>()
    }

    /// 按键取值（返回首个匹配；重复键场景用 getAll）。
    open public func get(key: String): ?Obj {
        for ((k, v) in entries()) {
            if (k == key) {
                return Some(v)
            }
        }
        None
    }

    /// 按键取全部值（允许重复键）。
    open public func getAll(key: String): ArrayList<Obj> {
        let out = ArrayList<Obj>()
        for ((k, v) in entries()) {
            if (k == key) {
                out.add(v)
            }
        }
        out
    }

    /// 按下标取值（仅 KSeq）。
    open public func at(index: Int64): ?Obj {
        let its = items()
        if (index < 0 || index >= its.size) {
            return None
        }
        Some(its[index])
    }

    /// 按点分路径访问，例如 "a.b.0"。
    open public func at(path: String): ?Obj {
        let segs = path.split(".", removeEmpty: true)
        var cur: Obj = this
        for (seg in segs) {
            // 尝试按下标
            var allDigits = seg.size > 0
            for (b in seg.toArray()) {
                if (b < 48 || b > 57) {
                    allDigits = false
                    break
                }
            }
            if (allDigits) {
                let idx = parseInt64(seg)
                if (let Some(n) <- idx) {
                    if (let Some(next) <- cur.at(n)) {
                        cur = next
                        continue
                    }
                    return None
                }
            }
            if (let Some(next) <- cur.get(seg)) {
                cur = next
            } else {
                return None
            }
        }
        Some(cur)
    }

    /// 枚举键值或元素（10.4）。
    open public func enumerate(): ArrayList<(String, Obj)> {
        if (objKindEq(kind, ObjKind.KMap)) {
            return entries()
        }
        let out = ArrayList<(String, Obj)>()
        for (i in 0..items().size) {
            out.add(("[${i}]", items()[i]))
        }
        out
    }

    /// 带控制的深度遍历（10.4）：进入回调返回 Continue/SkipSubtree/Stop。
    open public func walk(visitor: (Obj) -> WalkControl): Bool {
        let c = visitor(this)
        if (walkCtrlEq(c, WalkControl.Stop)) {
            return false
        }
        if (walkCtrlEq(c, WalkControl.SkipSubtree)) {
            return true
        }
        if (objKindEq(kind, ObjKind.KSeq)) {
            for (ch in items()) {
                if (!ch.walk(visitor)) {
                    return false
                }
            }
        } else if (objKindEq(kind, ObjKind.KMap)) {
            for ((_, v) in entries()) {
                if (!v.walk(visitor)) {
                    return false
                }
            }
        }
        true
    }

    /// 由节点反查原文区间（10.4）。
    open public func sourceSpan(): Span {
        span
    }

    /// 显式复制为不引用输入的独立结构（10.4/13.3）。
    public func toOwned(): Obj {
        deepCopy(None)
    }

    protected func deepCopy(ref: Option<Input>): Obj
}


/// 遍历控制枚举相等判断。
public func walkCtrlEq(a: WalkControl, b: WalkControl): Bool {
    match (a) {
        case WalkControl.Continue => match (b) { case WalkControl.Continue => true; case _ => false }
        case WalkControl.SkipSubtree => match (b) { case WalkControl.SkipSubtree => true; case _ => false }
        case WalkControl.Stop => match (b) { case WalkControl.Stop => true; case _ => false }
    }
}

/// 枚举相等判断（仓颉枚举不支持 ==）。
public func objKindEq(a: ObjKind, b: ObjKind): Bool {
    match (a) {
        case ObjKind.KNull => match (b) { case ObjKind.KNull => true; case _ => false }
        case ObjKind.KBool => match (b) { case ObjKind.KBool => true; case _ => false }
        case ObjKind.KNumber => match (b) { case ObjKind.KNumber => true; case _ => false }
        case ObjKind.KText => match (b) { case ObjKind.KText => true; case _ => false }
        case ObjKind.KSeq => match (b) { case ObjKind.KSeq => true; case _ => false }
        case ObjKind.KMap => match (b) { case ObjKind.KMap => true; case _ => false }
    }
}

/// Null。
public class ObjNull <: Obj {
    public init(span!: Span = Span(0, 0), formatTag!: String = "null", ref!: Option<Input> = None) {
        super(ObjKind.KNull, span, formatTag, ref)
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        ObjNull(span: span, formatTag: formatTag, ref: ref)
    }
}

/// Boolean。
public class ObjBool <: Obj {
    public let value: Bool

    public init(value: Bool, span!: Span = Span(0, 0), formatTag!: String = "bool", ref!: Option<Input> = None) {
        super(ObjKind.KBool, span, formatTag, ref)
        this.value = value
    }

    public override func asBool(): ?Bool {
        Some(value)
    }

    public override func asText(): ?String {
        if (value) { Some("true") } else { Some("false") }
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        ObjBool(value, span: span, formatTag: formatTag, ref: ref)
    }
}

/// Number：保留原文，按需解析，避免精度损失（10.2）。
public class ObjNumber <: Obj {
    public let rawValue: String

    public init(raw: String, span!: Span = Span(0, 0), formatTag!: String = "number", ref!: Option<Input> = None) {
        super(ObjKind.KNumber, span, formatTag, ref)
        this.rawValue = raw
    }

    public override func asInt(): ?Int64 {
        parseInt64(rawValue)
    }

    public override func asFloat(): ?Float64 {
        parseFloat64(rawValue)
    }

    public override func asText(): ?String {
        Some(rawValue)
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        ObjNumber(rawValue, span: span, formatTag: formatTag, ref: ref)
    }
}

/// Text：原文区间；含转义时按需解码（10.2）。
public class ObjText <: Obj {
    /// 未解码的原文。
    public let rawValue: String
    /// 转义形式标记（json 字符串转义、yaml 引号、xml 实体等）。
    public let escaped: Bool

    public init(raw: String, escaped!: Bool = false, span!: Span = Span(0, 0),
                formatTag!: String = "text", ref!: Option<Input> = None) {
        super(ObjKind.KText, span, formatTag, ref)
        this.rawValue = raw
        this.escaped = escaped
    }

    /// 按需解码：无转义时直接返回原文。
    public override func asText(): ?String {
        if (!escaped) {
            return Some(rawValue)
        }
        Some(decodeEscapes(rawValue, formatTag))
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        ObjText(rawValue, escaped: escaped, span: span, formatTag: formatTag, ref: ref)
    }
}

/// Sequence：有序序列。
public class ObjSeq <: Obj {
    public let elements: ArrayList<Obj>

    public init(span!: Span = Span(0, 0), formatTag!: String = "seq", ref!: Option<Input> = None) {
        super(ObjKind.KSeq, span, formatTag, ref)
        this.elements = ArrayList<Obj>()
    }

    public func add(v: Obj): Unit {
        elements.add(v)
    }

    public override func items(): ArrayList<Obj> {
        elements
    }

    public func size(): Int64 {
        elements.size
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        let out = ObjSeq(span: span, formatTag: formatTag, ref: ref)
        for (e in elements) {
            out.add(e.deepCopy(ref))
        }
        out
    }
}

/// Mapping：保持源顺序的键值序列，允许重复键（10.2）。
public class ObjMap <: Obj {
    public let pairs: ArrayList<(String, Obj)>

    public init(span!: Span = Span(0, 0), formatTag!: String = "map", ref!: Option<Input> = None) {
        super(ObjKind.KMap, span, formatTag, ref)
        this.pairs = ArrayList<(String, Obj)>()
    }

    public func put(key: String, v: Obj): Unit {
        pairs.add((key, v))
    }

    /// 同名键替换（保持首次出现位置；XML 同名子元素聚合用）。
    public func putReplace(key: String, v: Obj): Unit {
        var i = 0
        while (i < pairs.size) {
            if (pairs[i][0] == key) {
                pairs[i] = (key, v)
                return
            }
            i += 1
        }
        pairs.add((key, v))
    }

    public override func entries(): ArrayList<(String, Obj)> {
        pairs
    }

    public func size(): Int64 {
        pairs.size
    }

    protected override func deepCopy(ref: Option<Input>): Obj {
        let out = ObjMap(span: span, formatTag: formatTag, ref: ref)
        for ((k, v) in pairs) {
            out.put(k, v.deepCopy(ref))
        }
        out
    }
}

/// 解析 Int64（十进制，可带 +/-）。
public func parseInt64(s: String): ?Int64 {
    if (s.size == 0) {
        return None
    }
    var i: Int64 = 0
    var neg = false
    let bs = s.toArray()
    if (bs[0] == 45) { // '-'
        neg = true
        i = 1
    } else if (bs[0] == 43) { // '+'
        i = 1
    }
    if (i >= bs.size) {
        return None
    }
    var v: Int64 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (b < 48 || b > 57) {
            return None
        }
        v = v * 10 + Int64(b - 48)
        i += 1
    }
    Some(if (neg) { -v } else { v })
}

/// 解析 Float64（十进制与科学计数法）。
public func parseFloat64(s: String): ?Float64 {
    if (s.size == 0) {
        return None
    }
    var mantissa: Float64 = 0.0
    var fracDigits: Int64 = 0
    var exp: Int64 = 0
    var i: Int64 = 0
    var neg = false
    let bs = s.toArray()
    if (bs[0] == 45) {
        neg = true
        i = 1
    } else if (bs[0] == 43) {
        i = 1
    }
    if (i >= bs.size) {
        return None
    }
    var seenDigit = false
    var seenDot = false
    var seenExp = false
    var expNeg = false
    while (i < bs.size) {
        let b = bs[i]
        if (b >= 48 && b <= 57) {
            seenDigit = true
            if (!seenExp) {
                mantissa = mantissa * 10.0 + Float64(b - 48)
                if (seenDot) {
                    fracDigits += 1
                }
            } else {
                exp = exp * 10 + Int64(b - 48)
            }
        } else if (b == 46 && !seenDot && !seenExp) {
            seenDot = true
        } else if ((b == 101 || b == 69) && !seenExp && seenDigit) {
            seenExp = true
            if (i + 1 < bs.size && (bs[i + 1] == 43 || bs[i + 1] == 45)) {
                if (bs[i + 1] == 45) {
                    expNeg = true
                }
                i += 1
            }
        } else {
            return None
        }
        i += 1
    }
    if (!seenDigit) {
        return None
    }
    var v = mantissa
    var k = 0
    while (k < fracDigits) {
        v = v / 10.0
        k += 1
    }
    if (seenExp) {
        var e = if (expNeg) { -exp } else { exp }
        var p: Float64 = 1.0
        var cnt = if (e < 0) { -e } else { e }
        while (cnt > 0) {
            p = p * 10.0
            cnt -= 1
        }
        if (e < 0) {
            v = v / p
        } else {
            v = v * p
        }
    }
    Some(if (neg) { -v } else { v })
}

/// 按需解码转义字符串（formatTag 区分来源）。
public func decodeEscapes(s: String, formatTag: String): String {
    if (formatTag.startsWith("xml") || formatTag.startsWith("html")) {
        return xmlUnescape(s)
    }
    // JSON/YAML/TOML 的反斜杠转义
    let bs = s.toArray()
    let out = StringBuilder()
    var i: Int64 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (b == 92 && i + 1 < bs.size) { // backslash
            let c = bs[i + 1]
            if (c == 110) { // n
                out.append("\n")
                i += 2
                continue
            }
            if (c == 116) { // t
                out.append("\t")
                i += 2
                continue
            }
            if (c == 114) { // r
                out.append("\r")
                i += 2
                continue
            }
            if (c == 98) { // b
                out.append("\u{0008}")
                i += 2
                continue
            }
            if (c == 102) { // f
                out.append("\u{000C}")
                i += 2
                continue
            }
            if (c == 47) { // /
                out.append("/")
                i += 2
                continue
            }
            if (c == 34) { // "
                out.append("\"")
                i += 2
                continue
            }
            if (c == 92) { // backslash
                out.append("\\")
                i += 2
                continue
            }
            if (c == 117 && i + 6 <= bs.size) { // \uXXXX
                let hex = String.fromUtf8(bs[i + 2..i + 6])
                if (let Some(cp) <- parseHex(hex)) {
                    // 代理对
                    if (cp >= 0xD800 && cp <= 0xDBFF && i + 12 <= bs.size && bs[i + 6] == 92 && bs[i + 7] == 117) {
                        let hex2 = String.fromUtf8(bs[i + 8..i + 12])
                        if (let Some(lo) <- parseHex(hex2)) {
                            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                                let combined = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                                appendCodePoint(out, combined)
                                i += 12
                                continue
                            }
                        }
                    }
                    appendCodePoint(out, cp)
                    i += 6
                    continue
                }
            }
            out.append("\\")
            i += 1
            continue
        }
        out.append(String.fromUtf8([b]))
        i += 1
    }
    out.toString()
}

internal func parseHex(s: String): ?UInt32 {
    var v: UInt32 = 0
    for (b in s.toArray()) {
        var d: UInt32 = 0
        if (b >= 48 && b <= 57) {
            d = UInt32(b - 48)
        } else if (b >= 97 && b <= 102) {
            d = UInt32(b - 97 + 10)
        } else if (b >= 65 && b <= 70) {
            d = UInt32(b - 65 + 10)
        } else {
            return None
        }
        v = v * 16 + d
    }
    Some(v)
}

/// 将 Unicode 码点以 UTF-8 追加到 StringBuilder。
internal func appendCodePoint(sb: StringBuilder, cp: UInt32): Unit {
    if (cp < 0x80) {
        sb.append(String.fromUtf8([UInt8(cp)]))
    } else if (cp < 0x800) {
        sb.append(String.fromUtf8([UInt8(0xC0 | (cp >> 6)), UInt8(0x80 | (cp & 0x3F))]))
    } else if (cp < 0x10000) {
        sb.append(String.fromUtf8([UInt8(0xE0 | (cp >> 12)), UInt8(0x80 | ((cp >> 6) & 0x3F)), UInt8(0x80 | (cp & 0x3F))]))
    } else {
        sb.append(String.fromUtf8([UInt8(0xF0 | (cp >> 18)), UInt8(0x80 | ((cp >> 12) & 0x3F)), UInt8(0x80 | ((cp >> 6) & 0x3F)), UInt8(0x80 | (cp & 0x3F))]))
    }
}

/// XML/HTML 实体反转义（含常见命名实体与数字实体）。
public func xmlUnescape(s: String): String {
    var out = s
    out = out.replace("&lt;", "<")
    out = out.replace("&gt;", ">")
    out = out.replace("&quot;", "\"")
    out = out.replace("&apos;", "'")
    out = out.replace("&nbsp;", " ")
    out = out.replace("&amp;", "&")
    out
}

/// 类型断言辅助（`as` 返回 Option，这里统一解包；不匹配时返回带截断标记的哨兵）。
public func asMap(o: Obj): ObjMap {
    if (let Some(m) <- (o as ObjMap)) {
        return m
    }
    let d = ObjMap(span: o.span, formatTag: "invalid", ref: None)
    d.truncated = true
    d
}

public func asSeq(o: Obj): ObjSeq {
    if (let Some(q) <- (o as ObjSeq)) {
        return q
    }
    let d = ObjSeq(span: o.span, formatTag: "invalid", ref: None)
    d.truncated = true
    d
}

public func asTextObj(o: Obj): ObjText {
    if (let Some(t) <- (o as ObjText)) {
        return t
    }
    ObjText("", span: o.span, formatTag: "invalid", ref: None)
}
