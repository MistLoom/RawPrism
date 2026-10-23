// JSON / NDJSON 解析器：带原文偏移追踪、深度上限、有界试解析。
package rawprism.parse

import rawprism.core.*
import rawprism.object.*
import std.collection.*

/// 解析结果：成功携带对象树；失败携带错误位置。
public class ParseResult {
    public let ok: Bool
    public let value: Option<Obj>
    public let errorPos: Int64
    public let errorMessage: String
    /// 消耗的字节数（顶层值结束位置）。
    public let consumed: Int64

    public init(ok: Bool, value: Option<Obj>, errorPos: Int64, errorMessage: String, consumed: Int64) {
        this.ok = ok
        this.value = value
        this.errorPos = errorPos
        this.errorMessage = errorMessage
        this.consumed = consumed
    }

    public static func success(v: Obj, consumed: Int64): ParseResult {
        ParseResult(true, Some(v), -1, "", consumed)
    }

    public static func fail(pos: Int64, message: String): ParseResult {
        ParseResult(false, None, pos, message, 0)
    }
}

/// JSON 严格解析（整个输入必须是一个 JSON 值）。
public func parseJson(data: Array<UInt8>, limits!: ParseLimits = ParseLimits()): ParseResult {
    let p = JsonParser(data, 0, data.size, limits)
    let r = p.parseValue(0)
    if (!r.ok) {
        return r
    }
    p.skipWs()
    if (p.pos < p.end) {
        return ParseResult.fail(p.pos, "JSON 值之后存在多余内容")
    }
    ParseResult.success(r.value.getOrThrow(), p.pos)
}

/// JSON 有界试解析：从 start 开始尝试解析一个 JSON 值，成功返回消耗区间。
/// 失败时尽力确定该结构的作用域结束（供否定区间登记），返回 consumed 为试到的位置。
public func tryParseJson(data: Array<UInt8>, start: Int64, limits!: ParseLimits = ParseLimits()): ParseResult {
    if (start >= data.size) {
        return ParseResult.fail(start, "越界")
    }
    let b = data[start]
    if (b != 123 && b != 91) { // '{' '['
        return ParseResult.fail(start, "不是结构化起始")
    }
    let p = JsonParser(data, start, data.size, limits)
    let r = p.parseValue(0)
    if (!r.ok) {
        return r
    }
    ParseResult.success(r.value.getOrThrow(), p.pos)
}

/// NDJSON：逐行 JSON 值。返回成功的值与其区间；出错行记入错误列表。
public class NdjsonResult {
    public let values: ArrayList<(Obj, Span)>
    public let errors: ArrayList<(Int64, String)>  // (行起始偏移, 消息)

    public init() {
        this.values = ArrayList<(Obj, Span)>()
        this.errors = ArrayList<(Int64, String)>()
    }
}

public func parseNdjson(data: Array<UInt8>, limits!: ParseLimits = ParseLimits()): NdjsonResult {
    let out = NdjsonResult()
    var lineStart: Int64 = 0
    var i: Int64 = 0
    let n: Int64 = data.size
    while (i <= n) {
        if (i == n || data[i] == 10) { // '\n'
            var lineEnd = i
            if (lineEnd > lineStart && data[lineEnd - 1] == 13) {
                lineEnd -= 1
            }
            // 跳过空行
            var s = lineStart
            while (s < lineEnd && (data[s] == 32 || data[s] == 9)) {
                s += 1
            }
            if (s < lineEnd) {
                let p = JsonParser(data, s, lineEnd, limits)
                let r = p.parseValue(0)
                if (r.ok) {
                    p.skipWs()
                    if (p.pos < lineEnd) {
                        out.errors.add((lineStart, "行内 JSON 值之后存在多余内容"))
                    } else {
                        out.values.add((r.value.getOrThrow(), Span(s, p.pos)))
                    }
                } else {
                    out.errors.add((lineStart, r.errorMessage))
                }
            }
            lineStart = i + 1
        }
        i += 1
    }
    out
}

/// JSON 解析器。
internal class JsonParser {
    let data: Array<UInt8>
    var pos: Int64
    let start: Int64
    let end: Int64
    let limits: ParseLimits
    /// 深度截断时标记最外层节点。
    var truncatedFlag: Bool = false

    public init(data: Array<UInt8>, start: Int64, end: Int64, limits: ParseLimits) {
        this.data = data
        this.pos = start
        this.start = start
        this.end = end
        this.limits = limits
    }

    func skipWs(): Unit {
        while (pos < end) {
            let b = data[pos]
            if (b == 32 || b == 9 || b == 10 || b == 13) {
                pos += 1
            } else {
                break
            }
        }
    }

    /// 解析一个值；depth 用于深度限制。
    func parseValue(depth: Int64): ParseResult {
        skipWs()
        if (pos >= end) {
            return ParseResult.fail(pos, "输入提前结束")
        }
        if (depth > limits.maxDepth) {
            if (limits.truncateOnDepth) {
                truncatedFlag = true
                // 深度截断：跳过当前结构
                skipStructure()
                return ParseResult.fail(pos, "深度超限")
            }
            return ParseResult.fail(pos, "嵌套深度超过上限 ${limits.maxDepth}")
        }
        let b = data[pos]
        if (b == 123) {
            return parseObject(depth)
        }
        if (b == 91) {
            return parseArray(depth)
        }
        if (b == 34) {
            return parseString()
        }
        if (b == 116) {
            return parseLiteral("true", ObjBool(true, span: Span(start + pos - start, start + pos - start + 4), ref: None))
        }
        if (b == 102) {
            return parseLiteral("false", ObjBool(false))
        }
        if (b == 110) {
            return parseLiteral("null", ObjNull())
        }
        return parseNumber()
    }

    func parseLiteral(word: String, v: Obj): ParseResult {
        let w = word.toArray()
        var i: Int64 = 0
        while (i < w.size) {
            if (pos + i >= end || data[pos + i] != w[i]) {
                return ParseResult.fail(pos, "非法字面量")
            }
            i += 1
        }
        let s = pos
        pos += w.size
        let obj = relocateLiteral(v, s)
        ParseResult.success(obj, pos)
    }

    /// 重建字面量对象以携带正确区间。
    func relocateLiteral(v: Obj, s: Int64): Obj {
        if (objKindEq(v.kind, ObjKind.KBool)) {
            if (let Some(b) <- v.asBool()) {
                return ObjBool(b, span: Span(s, pos), ref: None)
            }
        }
        return ObjNull(span: Span(s, pos), ref: None)
    }

    func parseObject(depth: Int64): ParseResult {
        let objStart = pos
        let map = ObjMap(span: Span(start + objStart - start, 0), ref: None)
        pos += 1
        skipWs()
        if (pos < end && data[pos] == 125) { // '}'
            pos += 1
            map.span = Span(objStart, pos)
            return ParseResult.success(map, pos)
        }
        while (true) {
            skipWs()
            if (pos >= end) {
                return ParseResult.fail(pos, "对象未闭合")
            }
            if (data[pos] != 34) {
                return ParseResult.fail(pos, "对象键必须是字符串")
            }
            let kr = parseString()
            if (!kr.ok) {
                return kr
            }
            let casted = kr.value.getOrThrow() as ObjText
            let key = if (let Some(t) <- casted) { t.rawValue } else { "" }
            skipWs()
            if (pos >= end || data[pos] != 58) { // ':'
                return ParseResult.fail(pos, "缺少冒号")
            }
            pos += 1
            let vr = parseValue(depth + 1)
            if (!vr.ok) {
                return vr
            }
            map.put(key, vr.value.getOrThrow())
            skipWs()
            if (pos >= end) {
                return ParseResult.fail(pos, "对象未闭合")
            }
            if (data[pos] == 44) { // ','
                pos += 1
                continue
            }
            if (data[pos] == 125) {
                pos += 1
                break
            }
            return ParseResult.fail(pos, "对象中缺少逗号或右花括号")
        }
        map.span = Span(objStart, pos)
        if (map.span.length > limits.maxStructureLength) {
            map.truncated = true
        }
        ParseResult.success(map, pos)
    }

    func parseArray(depth: Int64): ParseResult {
        let arrStart = pos
        let arr = ObjSeq(span: Span(arrStart, 0), ref: None)
        pos += 1
        skipWs()
        if (pos < end && data[pos] == 93) { // ']'
            pos += 1
            arr.span = Span(arrStart, pos)
            return ParseResult.success(arr, pos)
        }
        while (true) {
            let vr = parseValue(depth + 1)
            if (!vr.ok) {
                return vr
            }
            arr.add(vr.value.getOrThrow())
            skipWs()
            if (pos >= end) {
                return ParseResult.fail(pos, "数组未闭合")
            }
            if (data[pos] == 44) {
                pos += 1
                continue
            }
            if (data[pos] == 93) {
                pos += 1
                break
            }
            return ParseResult.fail(pos, "数组中缺少逗号或右方括号")
        }
        arr.span = Span(arrStart, pos)
        if (arr.span.length > limits.maxStructureLength) {
            arr.truncated = true
        }
        ParseResult.success(arr, pos)
    }

    func parseString(): ParseResult {
        if (pos >= end || data[pos] != 34) {
            return ParseResult.fail(pos, "缺少引号")
        }
        let s = pos
        pos += 1
        while (pos < end) {
            let b = data[pos]
            if (b == 34) {
                pos += 1
                // rawValue 不含外层引号；span 仍覆盖带引号的完整原文区间
                let raw = String.fromUtf8(data[s + 1..pos - 1])
                let t = ObjText(raw, escaped: hasJsonEscape(raw), span: Span(s, pos), ref: None)
                return ParseResult.success(t, pos)
            }
            if (b == 92) { // backslash
                pos += 2
                continue
            }
            if (b < 0x20) {
                return ParseResult.fail(pos, "字符串中出现未转义控制字符")
            }
            pos += 1
        }
        return ParseResult.fail(s, "字符串未闭合")
    }

    func parseNumber(): ParseResult {
        let s = pos
        if (pos < end && (data[pos] == 45 || data[pos] == 43)) {
            pos += 1
        }
        var seenDigit = false
        var seenDot = false
        var seenExp = false
        while (pos < end) {
            let b = data[pos]
            if (b >= 48 && b <= 57) {
                seenDigit = true
                pos += 1
            } else if (b == 46 && !seenDot && !seenExp) {
                seenDot = true
                pos += 1
            } else if ((b == 101 || b == 69) && !seenExp && seenDigit) {
                seenExp = true
                pos += 1
                if (pos < end && (data[pos] == 43 || data[pos] == 45)) {
                    pos += 1
                }
            } else {
                break
            }
        }
        if (!seenDigit) {
            return ParseResult.fail(s, "非法数字")
        }
        let raw = String.fromUtf8(data[s..pos])
        return ParseResult.success(ObjNumber(raw, span: Span(s, pos), ref: None), pos)
    }

    /// 深度截断时跳过当前结构（有界扫描括号配对）。
    func skipStructure(): Unit {
        var depth = 0
        var inStr = false
        while (pos < end) {
            let b = data[pos]
            if (inStr) {
                if (b == 92) {
                    pos += 2
                    continue
                }
                if (b == 34) {
                    inStr = false
                }
                pos += 1
                continue
            }
            if (b == 34) {
                inStr = true
                pos += 1
                continue
            }
            if (b == 123 || b == 91) {
                depth += 1
            } else if (b == 125 || b == 93) {
                depth -= 1
                if (depth == 0) {
                    pos += 1
                    return
                }
            }
            pos += 1
        }
    }
}

/// 判断字符串原文中是否含转义序列。
public func hasJsonEscape(raw: String): Bool {
    for (b in raw.toArray()) {
        if (b == 92) {
            return true
        }
    }
    false
}
