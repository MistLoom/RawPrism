// RawPrism 核心类型：区间、类型标识、区域、类型标记。
package rawprism.core

import std.collection.*

/// [start, end) 偏移区间，相对整个输入起点，单位为 UTF-8 字节。
public struct Span {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        this.start = start
        this.end = end
    }

    public prop length: Int64 {
        get() { end - start }
    }

    public func contains(offset: Int64): Bool {
        offset >= start && offset < end
    }

    public func contains(other: Span): Bool {
        other.start >= start && other.end <= end
    }

    public func intersects(other: Span): Bool {
        other.start < end && other.end > start
    }

    public func isEmpty(): Bool {
        start >= end
    }
}

/// 层级化类型标识，例如 `struct.json`、`markup.html#text`、`code.block[lang=json]`。
/// 基础部分是点分层级名；`#` 后是子类型限定；`[k=v]` 是参数。
public struct TypeId {
    public let parts: Array<String>
    public let sub: Option<String>
    public let params: HashMap<String, String>

    public init(raw: String) {
        this.params = HashMap<String, String>()
        let bytes = raw.toArray()
        var baseEnd = bytes.size
        // 参数部分 [k=v,k2=v2]
        var i = 0
        var foundBracket = -1
        while (i < bytes.size) {
            if (bytes[i] == 91) { // '['
                foundBracket = i
                break
            }
            i += 1
        }
        if (foundBracket >= 0) {
            var close = -1
            var j = foundBracket + 1
            while (j < bytes.size) {
                if (bytes[j] == 93) { // ']'
                    close = j
                    break
                }
                j += 1
            }
            if (close > foundBracket) {
                let body = asciiString(bytes[foundBracket + 1..close])
                for (p in body.split(",", removeEmpty: true)) {
                    let eq = p.indexOf("=")
                    if (let Some(eqPos) <- eq) {
                        this.params[p[0..eqPos]] = p[eqPos + 1..p.size]
                    }
                }
                baseEnd = foundBracket
            }
        }
        var base = bytes[0..baseEnd]
        var subPart: Option<String> = None
        var hash = -1
        var k = 0
        while (k < base.size) {
            if (base[k] == 35) { // '#'
                hash = k
                break
            }
            k += 1
        }
        if (hash >= 0) {
            subPart = Some(asciiString(base[hash + 1..base.size]))
            base = base[0..hash]
        }
        this.sub = subPart
        var ps: ArrayList<String> = ArrayList<String>()
        let pieces = asciiString(base).split(".", removeEmpty: true)
        for (p in pieces) {
            ps.add(p)
        }
        this.parts = ps.toArray()
    }

    public init(parts: Array<String>, sub!: Option<String> = None,
                params!: HashMap<String, String> = HashMap<String, String>()) {
        this.parts = parts
        this.sub = sub
        this.params = params
    }

    /// 完整规范字符串。
    public prop text: String {
        get() {
            let sb = StringBuilder()
            for (i in 0..parts.size) {
                if (i > 0) {
                    sb.append(".")
                }
                sb.append(parts[i])
            }
            if (let Some(s) <- sub) {
                sb.append("#")
                sb.append(s)
            }
            sb.toString()
        }
    }

    /// 顶层类别（struct / markup / text / entity / code / doc / 自定义顶层名）。
    public prop category: String {
        get() { parts[0] }
    }

    /// 是否为选择器可用的通配形式（任一 part 为 *）。
    public func isWildcard(): Bool {
        for (p in parts) {
            if (p == "*") {
                return true
            }
        }
        false
    }

    /// 本类型是否匹配选择器。选择器支持：
    /// - 精确名：`struct.json`
    /// - 前缀形式：`text.md` 匹配 `text.md` 及其更深层级；`text` 匹配 `text.*` 族
    /// - 通配名：`text.*`
    /// - 子类型限定：`markup.html#text`（限定子类型）
    /// - 参数限定：`code.block[lang=json]`
    public func matches(selector: String): Bool {
        let sel = TypeId(selector)
        for ((k, v) in sel.params) {
            if (let Some(mine) <- params.get(k)) {
                if (mine != v) {
                    return false
                }
            } else {
                return false
            }
        }
        var i = 0
        while (i < sel.parts.size) {
            let want = sel.parts[i]
            if (i >= parts.size) {
                // 选择器以 .* 结尾且本类型正是该前缀：`text.*` 匹配 `text`？不匹配，前缀必须完整存在
                return false
            }
            if (want != "*" && want != parts[i]) {
                return false
            }
            i += 1
        }
        if (let Some(wantSub) <- sel.sub) {
            if (let Some(mySub) <- sub) {
                return mySub == wantSub
            }
            return false
        }
        true
    }

    /// 本类型是否匹配任一选择器。
    public func matchesAny(selectors: Array<String>): Bool {
        for (s in selectors) {
            if (matches(s)) {
                return true
            }
        }
        false
    }

    public static func parse(raw: String): TypeId {
        TypeId(raw)
    }
}

/// 从字节区间构建 ASCII 字符串（类型名与选择器均为 ASCII）。
internal func asciiString(bytes: Array<UInt8>): String {
    if (bytes.size == 0) {
        return ""
    }
    String.fromUtf8(bytes)
}

/// 类型标记状态。
public enum MarkStatus {
    | Unscanned
    | Partial
    | Done
}

/// 单个类型在某会话中的扫描状态（类型标记，8.1）。
public class TypeMark {
    public let typeIdText: String
    /// 已覆盖区间（无论是否命中），保持合并后的有序状态。
    public let covered: ArrayList<Span>
    /// 已登记区域。
    public let regions: ArrayList<Region>
    /// 候选区间（他人登记、未验证）。
    public let candidates: ArrayList<Span>
    /// 否定区间（已验证未命中）。
    public let negatives: ArrayList<Span>
    /// 错误区间。
    public let errors: ArrayList<Span>
    public var status: MarkStatus

    public init(typeIdText: String) {
        this.typeIdText = typeIdText
        this.covered = ArrayList<Span>()
        this.regions = ArrayList<Region>()
        this.candidates = ArrayList<Span>()
        this.negatives = ArrayList<Span>()
        this.errors = ArrayList<Span>()
        this.status = MarkStatus.Unscanned
    }

    public func addCovered(s: Span): Unit {
        mergeInto(covered, s)
    }

    public func addCandidate(s: Span): Unit {
        mergeInto(candidates, s)
    }

    public func addNegative(s: Span): Unit {
        mergeInto(negatives, s)
    }

    public func addError(s: Span): Unit {
        mergeInto(errors, s)
    }

    /// 计算 want 中未被 covered 覆盖的剩余区间（8.2 第 1 步）。
    public func uncovered(want: Span): ArrayList<Span> {
        let rest = ArrayList<Span>()
        var cur = want.start
        for (c in covered) {
            if (c.end <= cur) {
                continue
            }
            if (c.start > cur) {
                rest.add(Span(cur, minI(c.start, want.end)))
            }
            cur = maxI(cur, c.end)
            if (cur >= want.end) {
                break
            }
        }
        if (cur < want.end) {
            rest.add(Span(cur, want.end))
        }
        rest
    }

    /// 候选区间中与 s 相交的部分（优先验证）。
    public func candidatesIn(s: Span): ArrayList<Span> {
        let out = ArrayList<Span>()
        for (c in candidates) {
            if (c.intersects(s)) {
                out.add(c)
            }
        }
        out
    }
}

/// 有序合并插入区间集合（相邻、重叠合并），通过重建列表完成。
internal func mergeInto(list: ArrayList<Span>, s: Span): Unit {
    if (s.isEmpty()) {
        return
    }
    let out = ArrayList<Span>()
    var placed = false
    for (t in list) {
        if (!placed && t.start > s.start) {
            out.add(s)
            placed = true
        }
        out.add(t)
    }
    if (!placed) {
        out.add(s)
    }
    // 合并相邻/重叠区间
    let merged = ArrayList<Span>()
    for (t in out) {
        if (merged.size > 0) {
            let lastIdx = merged.size - 1
            let last = merged[lastIdx]
            if (last.start <= t.start && t.start <= last.end) {
                merged[lastIdx] = Span(last.start, maxI(last.end, t.end))
                continue
            }
        }
        merged.add(t)
    }
    list.clear()
    for (t in merged) {
        list.add(t)
    }
}

internal func minI(a: Int64, b: Int64): Int64 {
    if (a < b) { a } else { b }
}

/// Span 相等判断（结构体不支持 ==）。
public func spanEq(a: Span, b: Span): Bool {
    a.start == b.start && a.end == b.end
}

internal func maxI(a: Int64, b: Int64): Int64 {
    if (a > b) { a } else { b }
}

/// ASCII trim 辅助。
public func trimAscii(s: String): String {
    var b = 0
    var e = s.size
    let bs = s.toArray()
    while (b < e && (bs[b] == 32 || bs[b] == 9 || bs[b] == 10 || bs[b] == 13)) {
        b += 1
    }
    while (e > b && (bs[e - 1] == 32 || bs[e - 1] == 9 || bs[e - 1] == 10 || bs[e - 1] == 13)) {
        e -= 1
    }
    String.fromUtf8(bs[b..e])
}
