// 容错 XML / HTML 解析器：带原文偏移、不解析外部实体（14.3）、
// script/style 原文文本、void 元素、自闭合标签、属性值区间（供副产物登记）。
package rawprism.parse

import rawprism.core.*
import rawprism.object.*
import std.collection.*

/// 元素节点：属性、文本、子元素分别以约定键表示（10.3）：
/// "#attr"（Mapping）、"#text"（Text）、子元素以标签名聚合（同名 -> Sequence）、
/// 原始子节点顺序以 "#order" 保留（Sequence of Text(标签名)）。
/// XML 映射约定可配置：attrPrefix（默认 "#attr"）、textKey（"#text"）、orderKey（"#order"）。
public class XmlMappingConfig {
    public let attrKey: String
    public let textKey: String
    public let orderKey: String

    public init(attrKey!: String = "#attr", textKey!: String = "#text", orderKey!: String = "#order") {
        this.attrKey = attrKey
        this.textKey = textKey
        this.orderKey = orderKey
    }
}

/// 解析出的节点（中间表示，携带偏移）。
public class XmlNode {
    public let name: String            // 元素名；文本节点为 "#text"
    public var span: Span              // 元素整体区间（文本节点为文本区间）
    public var contentSpan: Span       // 元素内容区间（不含标签）
    public let attrs: ArrayList<(String, String, Span)>  // (名, 值, 值区间)
    public let children: ArrayList<XmlNode>
    public let isText: Bool
    public let textRaw: String
    public var selfClosed: Bool

    public init(name: String, span: Span, contentSpan!: Span = Span(0, 0),
                isText!: Bool = false, textRaw!: String = "", selfClosed!: Bool = false) {
        this.name = name
        this.span = span
        this.contentSpan = contentSpan
        this.attrs = ArrayList<(String, String, Span)>()
        this.children = ArrayList<XmlNode>()
        this.isText = isText
        this.textRaw = textRaw
        this.selfClosed = selfClosed
    }
}

public class XmlResult {
    public let roots: ArrayList<XmlNode>
    public let ok: Bool
    public let errorPos: Int64
    public let errorMessage: String

    public init(roots: ArrayList<XmlNode>, ok!: Bool = true, errorPos!: Int64 = -1, errorMessage!: String = "") {
        this.roots = roots
        this.ok = ok
        this.errorPos = errorPos
        this.errorMessage = errorMessage
    }
}

/// HTML 空元素（无结束标签）。
internal let HTML_VOID: Array<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr"]

/// 原文文本元素（内部内容不按标记解析）。
internal let HTML_RAW_TEXT: Array<String> = ["script", "style", "textarea", "title"]

public func parseXml(data: Array<UInt8>, start!: Int64 = 0, end!: Int64 = -1, html!: Bool = false,
                     limits!: ParseLimits = ParseLimits()): XmlResult {
    var e = end
    if (e < 0) {
        e = data.size
    }
    let p = XmlParser(data, start, e, html, limits)
    return p.parse()
}

/// 把 XML 节点树映射为统一对象模型（10.3）。
public func xmlToObj(node: XmlNode, ref: Option<Input>, cfg!: XmlMappingConfig = XmlMappingConfig()): Obj {
    if (node.isText) {
        let decoded = xmlUnescape(node.textRaw)
        return ObjText(decoded, escaped: true, span: node.span, formatTag: "xml:text", ref: ref)
    }
    let map = ObjMap(span: node.span, formatTag: "xml:element:${node.name}", ref: ref)
    // 属性
    if (node.attrs.size > 0) {
        let attrs = ObjMap(span: node.span, formatTag: "xml:attrs", ref: ref)
        for ((k, v, _) in node.attrs) {
            attrs.put(k, ObjText(xmlUnescape(v), escaped: true, span: node.span, formatTag: "xml:attr", ref: ref))
        }
        map.put(cfg.attrKey, attrs)
    }
    // 文本
    var text = StringBuilder()
    for (c in node.children) {
        if (c.isText) {
            text.append(xmlUnescape(c.textRaw))
        }
    }
    let textStr = text.toString()
    if (!textStr.isEmpty()) {
        map.put(cfg.textKey, ObjText(textStr, escaped: true, span: node.span, formatTag: "xml:text", ref: ref))
    }
    // 子元素：同名聚合为 Sequence；原始顺序单独保留
    let order = ObjSeq(span: node.span, formatTag: "xml:order", ref: ref)
    for (c in node.children) {
        if (c.isText) {
            continue
        }
        order.add(ObjText(c.name, escaped: false, span: c.span, formatTag: "xml:name", ref: ref))
    }
    if (order.size() > 0) {
        map.put(cfg.orderKey, order)
    }
    for (c in node.children) {
        if (c.isText) {
            continue
        }
        let childObj = xmlToObj(c, ref, cfg: cfg)
        if (let Some(existing) <- map.get(c.name)) {
            if (objKindEq(existing.kind, ObjKind.KSeq)) {
                asSeq(existing).add(childObj)
            } else {
                let seq = ObjSeq(span: existing.span, formatTag: "xml:list", ref: ref)
                seq.add(existing)
                seq.add(childObj)
                map.putReplace(c.name, seq)
            }
        } else {
            map.put(c.name, childObj)
        }
    }
    map
}

internal class XmlParser {
    let data: Array<UInt8>
    var pos: Int64
    let start: Int64
    let end: Int64
    let html: Bool
    let limits: ParseLimits

    public init(data: Array<UInt8>, start: Int64, end: Int64, html: Bool, limits: ParseLimits) {
        this.data = data
        this.pos = start
        this.start = start
        this.end = end
        this.html = html
        this.limits = limits
    }

    func parse(): XmlResult {
        let roots = parseChildren("", 0)
        XmlResult(roots)
    }

    /// 解析同级节点，直到遇到与 closeTag 匹配的结束标签或输入结束。
    func parseChildren(closeTag: String, depth: Int64): ArrayList<XmlNode> {
        let out = ArrayList<XmlNode>()
        var textStart = pos
        while (pos < end) {
            let b = data[pos]
            if (b == 60) { // '<'
                // 冲刷文本
                if (pos > textStart) {
                    let raw = String.fromUtf8(data[textStart..pos])
                    if (!trimWhitespaceOnly(raw).isEmpty()) {
                        out.add(XmlNode("#text", Span(textStart, pos), isText: true, textRaw: raw))
                    }
                }
                // 注释 / DOCTYPE / CDATA
                if (pos + 3 < end && data[pos + 1] == 33 && data[pos + 2] == 45 && data[pos + 3] == 45) {
                    // <!--
                    var j = pos + 4
                    while (j + 2 < end && !(data[j] == 45 && data[j + 1] == 45 && data[j + 2] == 62)) {
                        j += 1
                    }
                    pos = if (j + 3 <= end) { j + 3 } else { end }
                    textStart = pos
                    continue
                }
                if (pos + 8 < end && startsWith(data, pos, "<![CDATA[")) {
                    var j = pos + 9
                    while (j + 2 < end && !(data[j] == 93 && data[j + 1] == 93 && data[j + 2] == 62)) {
                        j += 1
                    }
                    let raw = String.fromUtf8(data[pos + 9..j])
                    out.add(XmlNode("#text", Span(pos + 9, j), isText: true, textRaw: raw))
                    pos = if (j + 3 <= end) { j + 3 } else { end }
                    textStart = pos
                    continue
                }
                if (pos + 1 < end && (data[pos + 1] == 33 || data[pos + 1] == 63)) {
                    // <!DOCTYPE 或 <?xml?>：跳过
                    var j = pos + 1
                    while (j < end && data[j] != 62) {
                        j += 1
                    }
                    pos = if (j < end) { j + 1 } else { end }
                    textStart = pos
                    continue
                }
                // 结束标签？
                if (pos + 1 < end && data[pos + 1] == 47) {
                    if (!closeTag.isEmpty()) {
                        let name = readTagName(pos + 2)
                        if (name == closeTag) {
                            // 跳过 </tag ...>
                            var j = pos + 2 + name.size
                            while (j < end && data[j] != 62) {
                                j += 1
                            }
                            pos = if (j < end) { j + 1 } else { end }
                            return out
                        }
                        // 不匹配的结束标签：容错——视为未闭合，返回
                        return out
                    }
                    // 顶层多余结束标签：跳过
                    var j = pos + 2
                    while (j < end && data[j] != 62) {
                        j += 1
                    }
                    pos = if (j < end) { j + 1 } else { end }
                    textStart = pos
                    continue
                }
                // 开始标签
                if (depth > limits.maxDepth) {
                    // 深度超限：跳过该标签
                    var j = pos + 1
                    while (j < end && data[j] != 62) {
                        j += 1
                    }
                    pos = if (j < end) { j + 1 } else { end }
                    textStart = pos
                    continue
                }
                let el = parseElement(depth)
                if (let Some(n) <- el) {
                    out.add(n)
                }
                textStart = pos
                continue
            }
            pos += 1
        }
        // 冲刷末尾文本
        if (pos > textStart) {
            let raw = String.fromUtf8(data[textStart..pos])
            if (!trimWhitespaceOnly(raw).isEmpty()) {
                out.add(XmlNode("#text", Span(textStart, pos), isText: true, textRaw: raw))
            }
        }
        out
    }

    func startsWith(data: Array<UInt8>, pos: Int64, word: String): Bool {
        let w = word.toArray()
        if (pos + w.size > end) {
            return false
        }
        var i: Int64 = 0
        while (i < w.size) {
            if (lowerByte(data[pos + i]) != lowerByte(w[i])) {
                return false
            }
            i += 1
        }
        true
    }

    func lowerByte(b: UInt8): UInt8 {
        if (b >= 65 && b <= 90) {
            return b + 32
        }
        b
    }

    /// 读取标签名（自 pos 起，到空白或 >）。
    func readTagName(from: Int64): String {
        var j = from
        while (j < end && data[j] != 32 && data[j] != 9 && data[j] != 10 && data[j] != 13 && data[j] != 62 && data[j] != 47) {
            j += 1
        }
        if (j > from) {
            return String.fromUtf8(data[from..j])
        }
        ""
    }

    /// 解析一个元素（pos 在 '<' 上）。
    func parseElement(depth: Int64): ?XmlNode {
        let elStart = pos
        pos += 1 // '<'
        let name = readTagName(pos)
        if (name.isEmpty()) {
            // 容错：非法标签，跳过 '<'
            pos = elStart + 1
            return None
        }
        pos += name.size
        let el = XmlNode(name, Span(elStart, elStart))
        // 属性
        while (pos < end) {
            // 跳过空白
            while (pos < end && (data[pos] == 32 || data[pos] == 9 || data[pos] == 10 || data[pos] == 13)) {
                pos += 1
            }
            if (pos >= end) {
                return Some(el)
            }
            let b = data[pos]
            if (b == 62) { // '>'
                pos += 1
                break
            }
            if (b == 47) { // '/'
                // 自闭合
                if (pos + 1 < end && data[pos + 1] == 62) {
                    pos += 2
                    el.span = Span(elStart, pos)
                    el.selfClosed = true
                    return Some(el)
                }
                pos += 1
                continue
            }
            // 属性名
            let attrStart = pos
            var j = pos
            while (j < end && data[j] != 61 && data[j] != 62 && data[j] != 47 && data[j] != 32 && data[j] != 9 &&
                   data[j] != 10 && data[j] != 13) {
                j += 1
            }
            if (j == attrStart) {
                pos += 1
                continue
            }
            let attrName = String.fromUtf8(data[attrStart..j])
            pos = j
            // 跳过空白与等号
            while (pos < end && (data[pos] == 32 || data[pos] == 9 || data[pos] == 10 || data[pos] == 13)) {
                pos += 1
            }
            if (pos < end && data[pos] == 61) {
                pos += 1
                while (pos < end && (data[pos] == 32 || data[pos] == 9 || data[pos] == 10 || data[pos] == 13)) {
                    pos += 1
                }
                if (pos < end && (data[pos] == 34 || data[pos] == 39)) {
                    let q = data[pos]
                    pos += 1
                    let vs = pos
                    while (pos < end && data[pos] != q) {
                        pos += 1
                    }
                    let valSpan = Span(vs, pos)
                    let val = if (pos > vs) { String.fromUtf8(data[vs..pos]) } else { "" }
                    if (pos < end) {
                        pos += 1
                    }
                    el.attrs.add((attrName, val, valSpan))
                } else if (pos < end) {
                    // 无引号属性值
                    let vs = pos
                    while (pos < end && data[pos] != 62 && data[pos] != 32 && data[pos] != 9 && data[pos] != 10) {
                        pos += 1
                    }
                    let valSpan = Span(vs, pos)
                    let val = if (pos > vs) { String.fromUtf8(data[vs..pos]) } else { "" }
                    el.attrs.add((attrName, val, valSpan))
                }
            } else {
                // 布尔属性
                el.attrs.add((attrName, "", Span(pos, pos)))
            }
        }
        el.span = Span(elStart, pos)
        // 内容
        let contentStart = pos
        let nameLower = toLowerAscii(name)
        if (html && inList(HTML_RAW_TEXT, nameLower)) {
            // 原文文本元素：到对应结束标签为止
            var j = pos
            while (j < end) {
                if (data[j] == 60 && j + 1 < end && data[j + 1] == 47) {
                    let cn = readTagName(j + 2)
                    if (toLowerAscii(cn) == nameLower) {
                        let content = String.fromUtf8(data[contentStart..j])
                        if (!trimWhitespaceOnly(content).isEmpty()) {
                            el.children.add(XmlNode("#text", Span(contentStart, j), isText: true, textRaw: content))
                        }
                        var k = j + 2 + cn.size
                        while (k < end && data[k] != 62) {
                            k += 1
                        }
                        pos = if (k < end) { k + 1 } else { end }
                        el.contentSpan = Span(contentStart, j)
                        el.span = Span(elStart, pos)
                        return Some(el)
                    }
                }
                j += 1
            }
            // 未闭合：内容到末尾
            el.contentSpan = Span(contentStart, end)
            el.span = Span(elStart, end)
            return Some(el)
        }
        let isVoid = html && inList(HTML_VOID, nameLower)
        if (!isVoid) {
            let kids = parseChildren(nameLower, depth + 1)
            for (k in kids) {
                el.children.add(k)
            }
        }
        el.contentSpan = Span(contentStart, pos)
        el.span = Span(elStart, pos)
        Some(el)
    }

    func inList(list: Array<String>, s: String): Bool {
        for (x in list) {
            if (x == s) {
                return true
            }
        }
        false
    }
}

/// ASCII 小写化（HTML 标签名处理用）。
public func toLowerAscii(s: String): String {
    let bs = s.toArray()
    let out = ArrayList<UInt8>()
    for (b in bs) {
        if (b >= 65 && b <= 90) {
            out.add(b + 32)
        } else {
            out.add(b)
        }
    }
    String.fromUtf8(out.toArray())
}

/// 仅去除首尾空白字符（ASCII 空白子集）。
public func trimWhitespaceOnly(s: String): String {
    let bs = s.toArray()
    var st: Int64 = 0
    var e: Int64 = bs.size
    while (st < e && (bs[st] == 32 || bs[st] == 9 || bs[st] == 10 || bs[st] == 13)) {
        st += 1
    }
    while (e > st && (bs[e - 1] == 32 || bs[e - 1] == 9 || bs[e - 1] == 10 || bs[e - 1] == 13)) {
        e -= 1
    }
    String.fromUtf8(bs[st..e])
}
