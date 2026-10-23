// TOML 解析器（子集）：表 [a.b]、键值对、基本字符串/字面量字符串、多行字符串、
// 整数/浮点/布尔、数组、内联表、日期时间（保留原文并带标签）。
package rawprism.parse

import rawprism.core.*
import rawprism.object.*
import std.collection.*

public class TomlResult {
    public let root: ObjMap
    public let ok: Bool
    public let errorPos: Int64
    public let errorMessage: String

    public init(root: ObjMap, ok!: Bool = true, errorPos!: Int64 = -1, errorMessage!: String = "") {
        this.root = root
        this.ok = ok
        this.errorPos = errorPos
        this.errorMessage = errorMessage
    }
}

public func parseToml(data: Array<UInt8>, start!: Int64 = 0, end!: Int64 = -1,
                      limits!: ParseLimits = ParseLimits()): TomlResult {
    var e = end
    if (e < 0) {
        e = data.size
    }
    let root = ObjMap(span: Span(start, e), formatTag: "toml", ref: None)
    // 当前表路径
    var tablePath: ArrayList<String> = ArrayList<String>()
    var i = start
    while (i < e) {
        // 跳过空白与注释
        while (i < e && (data[i] == 32 || data[i] == 9 || data[i] == 10 || data[i] == 13)) {
            i += 1
        }
        if (i >= e) {
            break
        }
        if (data[i] == 35) { // '#' 注释行
            while (i < e && data[i] != 10) {
                i += 1
            }
            continue
        }
        // 表头
        if (data[i] == 91) {
            var j = i + 1
            var isArrayTable = false
            if (j < e && data[j] == 91) {
                isArrayTable = true
                j += 1
            }
            var k = j
            while (k < e && data[k] != 93) {
                k += 1
            }
            if (k >= e) {
                return TomlResult(root, ok: false, errorPos: i, errorMessage: "表头未闭合")
            }
            var headerEnd = k
            if (isArrayTable && k + 1 < e && data[k + 1] == 93) {
                headerEnd = k + 1
            }
            let headerRaw = String.fromUtf8(data[j..k])
            let keys = parseTomlKeyPath(headerRaw)
            if (keys.size == 0) {
                return TomlResult(root, ok: false, errorPos: i, errorMessage: "空表头")
            }
            tablePath = keys
            // 确保表存在
            ensureTomlTable(root, keys, isArrayTable)
            i = if (isArrayTable) { headerEnd + 1 } else { headerEnd + 1 }
            // 跳到行尾
            while (i < e && data[i] != 10) {
                i += 1
            }
            continue
        }
        // 键值对
        let le = lineEnd(data, i, e)
        let line = String.fromUtf8(data[i..le])
        let eq = findTopLevel(line, "=")
        if (let None <- eq) {
            return TomlResult(root, ok: false, errorPos: i, errorMessage: "缺少等号")
        }
        let eqPos = eq.getOrThrow()
        let keyPart = trimAscii(line[0..eqPos])
        var valPart = trimAscii(line[eqPos + 1..line.size])
        // 剥离行尾注释（引号外）
        valPart = stripTomlComment(valPart)
        let keys = parseTomlKeyPath(keyPart)
        if (keys.size == 0) {
            return TomlResult(root, ok: false, errorPos: i, errorMessage: "空键")
        }
        let container = navigateTomlTable(root, tablePath)
        if (let None <- container) {
            return TomlResult(root, ok: false, errorPos: i, errorMessage: "目标表不可达")
        }
        let target = container.getOrThrow()
        // 相对键路径（a.b = v 支持）
        var parent: Obj = target
        var ki = 0
        while (ki < keys.size - 1) {
            let kname = keys[ki]
            var next: Obj = ObjNull(span: Span(i, i), ref: None)
            if (let Some(existing) <- parent.get(kname)) {
                next = existing
            } else {
                next = ObjMap(span: Span(i, le), formatTag: "toml", ref: None)
                asMap(parent).put(kname, next)
            }
            parent = next
            ki += 1
        }
        if (!objKindEq(parent.kind, ObjKind.KMap)) {
            return TomlResult(root, ok: false, errorPos: i, errorMessage: "键路径不是表")
        }
        let vr = parseTomlValue(valPart, Span(i, le), limits)
        if (let None <- vr) {
            return TomlResult(root, ok: false, errorPos: i, errorMessage: "值解析失败: ${valPart}")
        }
        asMap(parent).put(keys[keys.size - 1], vr.getOrThrow())
        i = le + 1
    }
    TomlResult(root)
}

/// 去除引号外的行尾注释。
internal func stripTomlComment(s: String): String {
    let bs = s.toArray()
    var inQ: UInt8 = 0
    var i: Int64 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (inQ != 0) {
            if (b == 92 && inQ == 34) {
                i += 2
                continue
            }
            if (b == inQ) {
                inQ = 0
            }
        } else if (b == 34 || b == 39) {
            inQ = b
        } else if (b == 35) {
            return String.fromUtf8(bs[0..i]).trimAscii()
        }
        i += 1
    }
    s
}

/// 找不在引号内的字符位置。
internal func findTopLevel(s: String, ch: String): ?Int64 {
    let bs = s.toArray()
    var inQ: UInt8 = 0
    var i: Int64 = 0
    let target = ch.toArray()[0]
    while (i < bs.size) {
        let b = bs[i]
        if (inQ != 0) {
            if (b == 92 && inQ == 34) {
                i += 2
                continue
            }
            if (b == inQ) {
                inQ = 0
            }
        } else if (b == 34 || b == 39) {
            inQ = b
        } else if (b == target) {
            return Some(i)
        }
        i += 1
    }
    None
}

/// 解析键路径 a.b.c 或 "a.b"。
internal func parseTomlKeyPath(s: String): ArrayList<String> {
    let out = ArrayList<String>()
    let bs = s.trimAscii().toArray()
    var i: Int64 = 0
    var cur = StringBuilder()
    var inQ: UInt8 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (inQ != 0) {
            if (b == inQ) {
                inQ = 0
            } else {
                cur.append(String.fromUtf8([b]))
            }
        } else if (b == 34 || b == 39) {
            inQ = b
        } else if (b == 46) {
            out.add(cur.toString())
            cur = StringBuilder()
        } else {
            cur.append(String.fromUtf8([b]))
        }
        i += 1
    }
    if (cur.toString().trimAscii().size > 0 || out.size == 0) {
        out.add(cur.toString().trimAscii())
    }
    out
}

/// 确保表头路径存在（数组表创建元素）。
internal func ensureTomlTable(root: ObjMap, keys: ArrayList<String>, isArrayTable: Bool): Unit {
    var cur: Obj = root
    var i = 0
    while (i < keys.size) {
        let k = keys[i]
        let isLast = i == keys.size - 1
        if (let Some(existing) <- asMap(cur).get(k)) {
            if (isLast && isArrayTable) {
                if (objKindEq(existing.kind, ObjKind.KSeq)) {
                    let el = ObjMap(span: existing.span, formatTag: "toml", ref: None)
                    asSeq(existing).add(el)
                }
                return
            }
            cur = existing
        } else {
            if (isLast && isArrayTable) {
                let seq = ObjSeq(span: Span(0, 0), formatTag: "toml", ref: None)
                let el = ObjMap(span: Span(0, 0), formatTag: "toml", ref: None)
                seq.add(el)
                asMap(cur).put(k, seq)
                return
            }
            let m = ObjMap(span: Span(0, 0), formatTag: "toml", ref: None)
            asMap(cur).put(k, m)
            cur = m
        }
        i += 1
    }
}

/// 导航到当前表（键值对写入目标）。
internal func navigateTomlTable(root: ObjMap, path: ArrayList<String>): ?ObjMap {
    var cur: Obj = root
    for (k in path) {
        if (!objKindEq(cur.kind, ObjKind.KMap)) {
            return None
        }
        if (let Some(next) <- asMap(cur).get(k)) {
            if (objKindEq(next.kind, ObjKind.KSeq)) {
                // 数组表：取最后一个元素
                let seq = asSeq(next)
                if (seq.size() > 0) {
                    cur = seq.items()[seq.size() - 1]
                    continue
                }
                return None
            }
            cur = next
        } else {
            let m = ObjMap(span: Span(0, 0), formatTag: "toml", ref: None)
            asMap(cur).put(k, m)
            cur = m
        }
    }
    if (objKindEq(cur.kind, ObjKind.KMap)) {
        return Some(asMap(cur))
    }
    None
}

/// 解析 TOML 值。
internal func parseTomlValue(s: String, span: Span, limits: ParseLimits): ?Obj {
    let t = s.trimAscii()
    if (t.isEmpty()) {
        return Some(ObjNull(span: span, ref: None))
    }
    let first = t.toArray()[0]
    // 基本字符串
    if (first == 34) {
        // 多行 """ 
        if (t.size >= 6 && t.startsWith("\"\"\"") && t.endsWith("\"\"\"")) {
            let inner = t[3..t.size - 3]
            return Some(ObjText(inner, escaped: true, span: span, formatTag: "toml:string", ref: None))
        }
        if (t.size >= 2 && t.endsWith("\"")) {
            let inner = t[1..t.size - 1]
            return Some(ObjText(inner, escaped: true, span: span, formatTag: "toml:string", ref: None))
        }
        return None
    }
    // 字面量字符串
    if (first == 39) {
        if (t.size >= 6 && t.startsWith("'''") && t.endsWith("'''")) {
            let inner = t[3..t.size - 3]
            return Some(ObjText(inner, escaped: false, span: span, formatTag: "toml:string", ref: None))
        }
        if (t.size >= 2 && t.endsWith("'")) {
            let inner = t[1..t.size - 1]
            return Some(ObjText(inner, escaped: false, span: span, formatTag: "toml:string", ref: None))
        }
        return None
    }
    // 数组
    if (first == 91) {
        if (!t.endsWith("]")) {
            return None
        }
        let seq = ObjSeq(span: span, formatTag: "toml:array", ref: None)
        let inner = t[1..t.size - 1]
        let parts = splitTomlTop(inner, 44)
        for (p in parts) {
            let pt = p.trimAscii()
            if (pt.isEmpty()) {
                continue
            }
            if (let None <- parseTomlValue(pt, span, limits)) {
                return None
            }
            seq.add(parseTomlValue(pt, span, limits).getOrThrow())
        }
        return Some(seq)
    }
    // 内联表
    if (first == 123) {
        if (!t.endsWith("}")) {
            return None
        }
        let map = ObjMap(span: span, formatTag: "toml:inline", ref: None)
        let inner = t[1..t.size - 1]
        let parts = splitTomlTop(inner, 44)
        for (p in parts) {
            let pt = p.trimAscii()
            if (pt.isEmpty()) {
                continue
            }
            let eq = findTopLevel(pt, "=")
            if (let None <- eq) {
                return None
            }
            let k = trimAscii(pt[0..eq.getOrThrow()])
            let keys = parseTomlKeyPath(k)
            if (keys.size != 1) {
                return None
            }
            let v = parseTomlValue(pt[eq.getOrThrow() + 1..pt.size], span, limits)
            if (let None <- v) {
                return None
            }
            map.put(keys[0], v.getOrThrow())
        }
        return Some(map)
    }
    // 布尔
    if (t == "true") {
        return Some(ObjBool(true, span: span, formatTag: "toml:bool", ref: None))
    }
    if (t == "false") {
        return Some(ObjBool(false, span: span, formatTag: "toml:bool", ref: None))
    }
    // 日期时间（保留原文并带标签）：yyyy-mm-dd / 带时间 / 带时区
    if (isTomlDateTime(t)) {
        return Some(ObjText(t, escaped: false, span: span, formatTag: "toml:datetime", ref: None))
    }
    // 数字（TOML 允许下划线分隔）
    let num = t.replace("_", "")
    if (let Some(i) <- parseInt64(num)) {
        return Some(ObjNumber(t, span: span, formatTag: "toml:int", ref: None))
    }
    if (let Some(f) <- parseFloat64(num)) {
        return Some(ObjNumber(t, span: span, formatTag: "toml:float", ref: None))
    }
    None
}

/// 日期时间形状判断。
internal func isTomlDateTime(s: String): Bool {
    let bs = s.toArray()
    // 至少 yyyy-mm-dd
    if (bs.size < 8) {
        return false
    }
    var digits = 0
    var dashes = 0
    var colons = 0
    for (b in bs) {
        if (b >= 48 && b <= 57) {
            digits += 1
        } else if (b == 45) {
            dashes += 1
        } else if (b == 58) {
            colons += 1
        }
    }
    // 纯数字含连字符不足判为日期；须含 4-2-2 形状或时间冒号
    if (colons > 0 && digits >= 4) {
        return true
    }
    if (dashes == 2 && digits >= 6) {
        return true
    }
    // 本地时间 12:34:56
    if (colons >= 2 && digits >= 4) {
        return true
    }
    false
}

/// 顶层逗号分割（考虑引号与嵌套括号）。
internal func splitTomlTop(s: String, sep: UInt8): Array<String> {
    let out = ArrayList<String>()
    let bs = s.toArray()
    var depth = 0
    var inQ: UInt8 = 0
    var segStart: Int64 = 0
    var i: Int64 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (inQ != 0) {
            if (b == 92 && inQ == 34) {
                i += 2
                continue
            }
            if (b == inQ) {
                inQ = 0
            }
        } else if (b == 34 || b == 39) {
            inQ = b
        } else if (b == 91 || b == 123) {
            depth += 1
        } else if (b == 93 || b == 125) {
            depth -= 1
        } else if (b == sep && depth == 0) {
            out.add(String.fromUtf8(bs[segStart..i]))
            segStart = i + 1
        }
        i += 1
    }
    out.add(String.fromUtf8(bs[segStart..bs.size]))
    out.toArray()
}
