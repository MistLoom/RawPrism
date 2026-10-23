// YAML 解析器（子集）：块映射、块序列、流式集合、注释、多文档、
// 锚点与别名（展开次数设上限，14.2）、YAML 1.2 Core Schema 标量推断、tag 保留。
package rawprism.parse

import rawprism.core.*
import rawprism.object.*
import std.collection.*

/// YAML 别名展开上限（14.2：防止指数级展开）。
public const MAX_ALIAS_EXPANSIONS: Int64 = 10000

public class YamlDocument {
    public let root: Obj
    public let span: Span
    /// 保留的 tag（若有）。
    public let tags: ArrayList<String>

    public init(root: Obj, span: Span, tags: ArrayList<String>) {
        this.root = root
        this.span = span
        this.tags = tags
    }
}

public class YamlResult {
    public let documents: ArrayList<YamlDocument>
    public let errorPos: Int64
    public let errorMessage: String

    public init(documents: ArrayList<YamlDocument>, errorPos!: Int64 = -1, errorMessage!: String = "") {
        this.documents = documents
        this.errorPos = errorPos
        this.errorMessage = errorMessage
    }

    public prop ok: Bool {
        get() { errorMessage.isEmpty() }
    }
}

/// YAML 解析入口。data 为输入字节，[start, end) 为候选区间。
public func parseYaml(data: Array<UInt8>, start!: Int64 = 0, end!: Int64 = -1,
                      limits!: ParseLimits = ParseLimits()): YamlResult {
    var e = end
    if (e < 0) {
        e = data.size
    }
    let p = YamlParser(data, start, e, limits)
    return p.parse()
}

/// front matter 便捷解析：输入以 --- 开头、以 --- 或 ... 结束的部分。
/// 返回文档对象与 front matter 的内部内容区间（不含定界行）。
public func parseFrontMatter(data: Array<UInt8>, start: Int64, end: Int64,
                             limits!: ParseLimits = ParseLimits()): ?(YamlDocument, Span) {
    var i = start
    // 第一行必须是 ---
    if (!lineStartsWith(data, i, end, "---")) {
        return None
    }
    i = lineEnd(data, i, end) + 1
    let bodyStart = i
    var j = i
    while (j < end) {
        if (lineStartsWith(data, j, end, "---") || lineStartsWith(data, j, end, "...")) {
            let bodyEnd = if (j > bodyStart && data[j - 1] == 10) { j - 1 } else { j }
            let p = YamlParser(data, bodyStart, bodyEnd, limits)
            let r = p.parse()
            if (!r.ok || r.documents.size != 1) {
                return None
            }
            return Some((r.documents[0], Span(bodyStart, bodyEnd)))
        }
        j = lineEnd(data, j, end) + 1
    }
    None
}

public func lineStartsWith(data: Array<UInt8>, pos: Int64, end: Int64, word: String): Bool {
    let w = word.toArray()
    if (pos + w.size > end) {
        return false
    }
    var k: Int64 = 0
    while (k < w.size) {
        if (data[pos + k] != w[k]) {
            return false
        }
        k += 1
    }
    // 后面必须是行尾或空白
    if (pos + w.size < end) {
        let b = data[pos + w.size]
        if (b != 32 && b != 9 && b != 10 && b != 13) {
            return false
        }
    }
    true
}

public func lineEnd(data: Array<UInt8>, pos: Int64, end: Int64): Int64 {
    var i = pos
    while (i < end && data[i] != 10) {
        i += 1
    }
    if (i > pos && data[i - 1] == 13) {
        return i - 1
    }
    i
}

internal class YamlParser {
    let data: Array<UInt8>
    var pos: Int64
    let start: Int64
    let end: Int64
    let limits: ParseLimits
    var aliasCount: Int64 = 0
    let anchors: HashMap<String, Obj> = HashMap<String, Obj>()
    let tags: ArrayList<String> = ArrayList<String>()

    public init(data: Array<UInt8>, start: Int64, end: Int64, limits: ParseLimits) {
        this.data = data
        this.pos = start
        this.start = start
        this.end = end
        this.limits = limits
    }

    func parse(): YamlResult {
        let docs = ArrayList<YamlDocument>()
        while (true) {
            skipBlankAndComments()
            if (pos >= end) {
                break
            }
            // 文档定界
            if (lineStartsWith(data, pos, end, "---")) {
                pos = lineEnd(data, pos, end) + 1
                skipBlankAndComments()
                if (pos >= end) {
                    break
                }
            }
            let docStart = pos
            let v = parseBlockNode(0)
            if (let None <- v) {
                return YamlResult(docs, errorPos: pos, errorMessage: "YAML 解析失败")
            }
            let node = v.getOrThrow()
            docs.add(YamlDocument(node, Span(docStart, pos), tags))
            skipBlankAndComments()
            if (pos < end && lineStartsWith(data, pos, end, "...")) {
                pos = lineEnd(data, pos, end) + 1
            } else if (pos < end && !lineStartsWith(data, pos, end, "---")) {
                // 同一段落继续解析（多文档无定界时按整体）
                break
            }
        }
        YamlResult(docs)
    }

    func skipBlankAndComments(): Unit {
        while (pos < end) {
            let b = data[pos]
            if (b == 10 || b == 13 || b == 32 || b == 9) {
                pos += 1
            } else if (b == 35) { // '#' 注释
                while (pos < end && data[pos] != 10) {
                    pos += 1
                }
            } else {
                break
            }
        }
    }

    /// 解析块节点（映射 / 序列 / 标量）。
    func parseBlockNode(depth: Int64): ?Obj {
        if (depth > limits.maxDepth) {
            return None
        }
        skipBlankAndComments()
        if (pos >= end) {
            return None
        }
        // tag 前缀
        var tag: Option<String> = None
        if (data[pos] == 33) { // '!'
            var j = pos
            while (j < end && data[j] != 32 && data[j] != 10) {
                j += 1
            }
            tag = Some(String.fromUtf8(data[pos..j]))
            tags.add(tag.getOrThrow())
            pos = j
            skipBlankAndComments()
            if (pos >= end) {
                return ObjNull(span: Span(pos, pos), ref: None)
            }
        }
        let b = data[pos]
        // 锚点 &name（值可在同行、后续行或嵌套块）
        if (b == 38) {
            var j = pos + 1
            while (j < end && data[j] != 32 && data[j] != 10) {
                j += 1
            }
            let name = String.fromUtf8(data[pos + 1..j])
            pos = j
            skipBlankAndComments()
            if (pos >= end) {
                let nullNode = ObjNull(span: Span(pos, pos), ref: None)
                anchors[name] = nullNode
                return Some(nullNode)
            }
            if (let Some(v) <- parseBlockNode(depth)) {
                anchors[name] = v
                return Some(v)
            }
            return None
        }
        // 别名 *name（展开次数有上限）
        if (b == 42) {
            var j = pos + 1
            while (j < end && data[j] != 32 && data[j] != 10 && data[j] != 44 && data[j] != 125 && data[j] != 93) {
                j += 1
            }
            let name = String.fromUtf8(data[pos + 1..j])
            pos = j
            if (let Some(v) <- anchors.get(name)) {
                aliasCount += 1
                if (aliasCount > MAX_ALIAS_EXPANSIONS) {
                    return None
                }
                // 别名引用同一节点（10.3），不复制
                return Some(v)
            }
            return None
        }
        // 块序列
        if (b == 45 && isBlankOrEnd(pos + 1)) {
            return parseBlockSeq(indentOf(pos), depth, tag)
        }
        // 块映射：尝试 key:
        if (let Some(_) <- findKeyColon()) {
            return parseBlockMap(indentOf(pos), depth, tag)
        }
        // 流式集合或标量
        return parseFlowOrScalar(tag)
    }

    func indentOf(p: Int64): Int64 {
        var i = p
        var n: Int64 = 0
        while (i > start && data[i - 1] != 10) {
            i -= 1
        }
        while (i < end && data[i] == 32) {
            n += 1
            i += 1
        }
        n
    }

    func isBlankOrEnd(p: Int64): Bool {
        p >= end || data[p] == 32 || data[p] == 10 || data[p] == 13 || data[p] == 9
    }

    /// 在当前行内查找 "key:" 的冒号位置（键后紧跟冒号+空格/行尾）。
    func findKeyColon(): ?Int64 {
        var i = pos
        var lineE = lineEnd(data, pos, end)
        var inQuote: UInt8 = 0
        while (i < lineE) {
            let b = data[i]
            if (inQuote != 0) {
                if (b == inQuote) {
                    inQuote = 0
                } else if (b == 92 && inQuote == 34) {
                    i += 1
                }
            } else if (b == 34 || b == 39) {
                inQuote = b
            } else if (b == 58) { // ':'
                if (i + 1 >= lineE || data[i + 1] == 32 || data[i + 1] == 9) {
                    return Some(i)
                }
            }
            i += 1
        }
        None
    }

    func parseBlockSeq(indent: Int64, depth: Int64, tag: Option<String>): ?Obj {
        let seqStart = pos
        let seq = ObjSeq(span: Span(seqStart, seqStart), ref: None)
        if (let Some(t) <- tag) {
            seq.formatTag = t
        }
        while (pos < end) {
            skipBlankAndComments()
            if (pos >= end) {
                break
            }
            let lineInd = indentOf(pos)
            if (lineInd < indent) {
                break
            }
            if (!(data[pos] == 45 && isBlankOrEnd(pos + 1)) && lineInd > indent) {
                break
            }
            if (!(data[pos] == 45 && isBlankOrEnd(pos + 1))) {
                break
            }
            pos += 1 // 跳过 '-'
            while (pos < end && (data[pos] == 32)) {
                pos += 1
            }
            if (pos >= end || data[pos] == 10) {
                // 值在后续行
                skipBlankAndComments()
                if (pos < end && indentOf(pos) > indent) {
                    if (let Some(child) <- parseBlockNode(depth + 1)) {
                        seq.add(child)
                    }
                } else {
                    seq.add(ObjNull(span: Span(pos, pos), ref: None))
                }
            } else {
                if (let Some(child) <- parseInlineValueAfterDash(depth)) {
                    seq.add(child)
                } else {
                    return None
                }
            }
        }
        seq.span = Span(seqStart, pos)
        seq
    }

    /// 解析 '- ' 之后的行内值（可能是内联标量或嵌套映射的首键）。
    func parseInlineValueAfterDash(depth: Int64): ?Obj {
        if (let Some(_) <- findKeyColon()) {
            // 嵌套映射，缩进以当前 pos 为准
            let ind = pos - lineStartOf(pos)
            if (let Some(m) <- parseBlockMap(ind, depth + 1, None)) {
                return Some(m)
            }
            return None
        }
        parseFlowOrScalar(None)
    }

    func lineStartOf(p: Int64): Int64 {
        var i = p
        while (i > start && data[i - 1] != 10) {
            i -= 1
        }
        i
    }

    func parseBlockMap(indent: Int64, depth: Int64, tag: Option<String>): ?Obj {
        let mapStart = pos
        let map = ObjMap(span: Span(mapStart, mapStart), ref: None)
        if (let Some(t) <- tag) {
            map.formatTag = t
        }
        while (pos < end) {
            skipBlankAndComments()
            if (pos >= end) {
                break
            }
            // 用键列号（相对行首）而非行首空格数：序列内联映射项的键不在行首
            let lineInd = pos - lineStartOf(pos)
            if (lineInd < indent) {
                break
            }
            if (lineInd > indent) {
                break
            }
            if (lineStartsWith(data, pos, end, "---") || lineStartsWith(data, pos, end, "...")) {
                break
            }
            let colon = findKeyColon()
            if (let None <- colon) {
                break
            }
            let c = colon.getOrThrow()
            let keyRaw = String.fromUtf8(data[pos..c])
            let key = unquoteScalar(keyRaw)
            pos = c + 1
            while (pos < end && (data[pos] == 32 || data[pos] == 9)) {
                pos += 1
            }
            if (pos >= end || data[pos] == 10 || data[pos] == 35) {
                // 值在后续行（或空值）
                let nl = lineEnd(data, pos, end) + 1
                var j = nl
                while (j < end && data[j] == 32) {
                    j += 1
                }
                // 同缩进序列：下一行与键同缩进且为 "- " 项
                var sameIndentSeq = false
                if (j < end && indentOf(j) == indent && data[j] == 45 && isBlankOrEnd(j + 1)) {
                    sameIndentSeq = true
                }
                if (sameIndentSeq) {
                    if (let Some(child) <- parseBlockSeq(indent, depth + 1, None)) {
                        map.put(key, child)
                    } else {
                        return None
                    }
                } else if (j < end && indentOf(j) > indent) {
                    pos = j
                    if (let Some(child) <- parseBlockNode(depth + 1)) {
                        map.put(key, child)
                    } else {
                        return None
                    }
                } else {
                    pos = nl
                    map.put(key, ObjNull(span: Span(c, nl), ref: None))
                }
            } else {
                // 行内值：可能是流式标量、流式集合或嵌套块
                if (data[pos] == 33 || data[pos] == 38 || data[pos] == 42) {
                    // tag / 锚点 / 别名：交给块节点解析（支持嵌套块值）
                    if (let Some(child) <- parseBlockNode(depth + 1)) {
                        map.put(key, child)
                    } else {
                        return None
                    }
                } else if (data[pos] == 123 || data[pos] == 91 || data[pos] == 34 || data[pos] == 39 ||
                           data[pos] == 124 || data[pos] == 62) {
                    if (let Some(child) <- parseFlowOrScalar(None)) {
                        map.put(key, child)
                    } else {
                        return None
                    }
                } else if (data[pos] == 45 && isBlankOrEnd(pos + 1)) {
                    let ind = indentOf(pos)
                    if (let Some(child) <- parseBlockSeq(ind, depth + 1, None)) {
                        map.put(key, child)
                    } else {
                        return None
                    }
                } else {
                    // 行内简单标量到行尾（剥离注释）
                    var e = lineEnd(data, pos, end)
                    // 剥离行尾注释
                    var k = pos
                    var inQ: UInt8 = 0
                    while (k < e) {
                        let b2 = data[k]
                        if (inQ != 0) {
                            if (b2 == inQ) {
                                inQ = 0
                            }
                        } else if (b2 == 34 || b2 == 39) {
                            inQ = b2
                        } else if (b2 == 35 && k > pos && data[k - 1] == 32) {
                            e = k
                            break
                        }
                        k += 1
                    }
                    var vEnd = e
                    while (vEnd > pos && (data[vEnd - 1] == 32 || data[vEnd - 1] == 9)) {
                        vEnd -= 1
                    }
                    // 值后可能是同键嵌套块（多行）
                    let sc = scalarNode(pos, vEnd)
                    // 多行纯标量：后续行缩进更深且不是键/项形状时并入（换行折叠为空格）
                    var isPlain = true
                    if (vEnd > pos) {
                        let fb = data[pos]
                        if (fb == 34 || fb == 39 || fb == 124 || fb == 62) {
                            isPlain = false
                        }
                    }
                    var folded = sc
                    var foldedAny = false
                    if (isPlain && vEnd > pos) {
                        var peek = lineEnd(data, pos, end) + 1
                        var cont = StringBuilder()
                        var any = false
                        // 标记是否消费了续行（供 pos 推进判断）
                        while (peek < end) {
                            let le2 = lineEnd(data, peek, end)
                            var blank = true
                            var k2 = peek
                            while (k2 < le2) {
                                if (data[k2] != 32 && data[k2] != 9 && data[k2] != 13) {
                                    blank = false
                                    break
                                }
                                k2 += 1
                            }
                            if (blank) {
                                break
                            }
                            let lineInd = indentOf(peek)
                            if (lineInd <= indentOf(mapStart)) {
                                break
                            }
                            let lineText = String.fromUtf8(data[peek..le2]).trimAscii()
                            // 续行不能是新键或新项
                            if (findKeyColonIn(lineText) || lineText.startsWith("- ")) {
                                break
                            }
                            if (any) {
                                cont.append(" ")
                            }
                            cont.append(lineText)
                            any = true
                            peek = if (le2 < end) { le2 + 1 } else { end }
                        }
                        if (any) {
                            let base = sc.asText().getOrThrow()
                            let joined = base + " " + cont.toString()
                            folded = ObjText(joined, escaped: false, span: Span(pos, peek),
                                formatTag: "yaml:str", ref: None)
                            pos = peek
                            foldedAny = true
                        }
                    }
                    map.put(key, folded)
                    if (!foldedAny) {
                        pos = lineEnd(data, pos, end)
                    }
                }
            }
        }
        map.span = Span(mapStart, pos)
        map
    }

    /// 流式集合、引号标量、块标量、锚点/别名、普通标量。
    func parseFlowOrScalar(tag: Option<String>): ?Obj {
        if (pos >= end) {
            return None
        }
        let b = data[pos]
        // 锚点 &name
        if (b == 38) {
            var j = pos + 1
            while (j < end && data[j] != 32 && data[j] != 10) {
                j += 1
            }
            let name = String.fromUtf8(data[pos + 1..j])
            pos = j
            while (pos < end && data[pos] == 32) {
                pos += 1
            }
            if (let Some(v) <- parseFlowOrScalar(tag)) {
                anchors[name] = v
                return Some(v)
            }
            return None
        }
        // 别名 *name（展开计数有上限）
        if (b == 42) {
            var j = pos + 1
            while (j < end && data[j] != 32 && data[j] != 10 && data[j] != 44 && data[j] != 125 && data[j] != 93) {
                j += 1
            }
            let name = String.fromUtf8(data[pos + 1..j])
            pos = j
            if (let Some(v) <- anchors.get(name)) {
                aliasCount += 1
                if (aliasCount > MAX_ALIAS_EXPANSIONS) {
                    return None
                }
                // 别名引用同一节点（10.3），不复制
                return Some(v)
            }
            return None
        }
        // 块标量 | 与 >
        if (b == 124 || b == 62) {
            return parseBlockScalar(b)
        }
        // 流式集合
        if (b == 123) {
            return parseFlowMap()
        }
        if (b == 91) {
            return parseFlowSeq()
        }
        // 引号标量
        if (b == 34) {
            let r = readDoubleQuoted()
            if (let Some((raw, s, e)) <- r) {
                return Some(ObjText(raw, escaped: true, span: Span(s, e), formatTag: ifTag(tag, "text"), ref: None))
            }
            return None
        }
        if (b == 39) {
            let r = readSingleQuoted()
            if (let Some((raw, s, e)) <- r) {
                return Some(ObjText(raw, escaped: false, span: Span(s, e), formatTag: ifTag(tag, "text"), ref: None))
            }
            return None
        }
        // 普通标量到行尾（剥离注释）
        var e = lineEnd(data, pos, end)
        var k = pos
        while (k < e) {
            if (data[k] == 35 && k > pos && data[k - 1] == 32) {
                e = k
                break
            }
            k += 1
        }
        var vEnd = e
        while (vEnd > pos && (data[vEnd - 1] == 32 || data[vEnd - 1] == 9)) {
            vEnd -= 1
        }
        if (vEnd == pos) {
            let sp = Span(pos, pos)
            pos = e
            return Some(ObjNull(span: sp, ref: None))
        }
        let sc = scalarNode(pos, vEnd)
        if (let Some(t) <- tag) {
            sc.formatTag = t
        }
        // 只推进到标量结束：流式集合中后续的 ] / } 不被吞掉
        pos = vEnd
        Some(sc)
    }

    func ifTag(tag: Option<String>, dflt: String): String {
        if (let Some(t) <- tag) {
            return t
        }
        dflt
    }

    /// 块标量（| 保留换行 / > 折叠换行）。
    /// 块标量：| 保留换行、> 折叠换行；
    /// 指示符：- 剥离（无尾换行）、+ 保留（全部尾换行）、缺省裁剪（单个尾换行）；
    /// 可带显式缩进数字（如 |2）。
    func parseBlockScalar(marker: UInt8): ?Obj {
        let s = pos
        pos += 1
        // 解析头部指示符：数字（显式缩进）、-/+（剥离/保留）
        var chomp = 0  // -1 剥离 0 裁剪 1 保留
        var explicitIndent: Int64 = -1
        while (pos < end && data[pos] != 10 && data[pos] != 13) {
            let c = data[pos]
            if (c == 45) { // '-'
                chomp = -1
            } else if (c == 43) { // '+'
                chomp = 1
            } else if (c >= 49 && c <= 57) { // '1'-'9'
                explicitIndent = Int64(c - 48)
            } else if (c == 32 || c == 9 || c == 35) {
                // 空白或注释：到行尾
                if (c == 35) {
                    while (pos < end && data[pos] != 10) {
                        pos += 1
                    }
                    break
                }
            }
            pos += 1
        }
        if (pos < end) {
            pos += 1
        }
        // 收集内容行（以首个非空行缩进为基准；显式缩进优先）
        let lines = ArrayList<String>()
        var trailingBlanks: Int64 = 0
        var baseIndent: Int64 = explicitIndent
        while (pos < end) {
            let ls = lineStartOf(pos)
            var ind: Int64 = 0
            var i = ls
            while (i < end && data[i] == 32) {
                ind += 1
                i += 1
            }
            if (i >= end || data[i] == 10) {
                // 空行：计入尾部空行，属于内容的一部分
                lines.add("")
                trailingBlanks += 1
                pos = if (i < end) { i + 1 } else { i }
                continue
            }
            if (baseIndent < 0) {
                baseIndent = ind
            }
            if (ind < baseIndent) {
                break
            }
            var le = lineEnd(data, ls, end)
            var content = ""
            if (le > ls + baseIndent) {
                content = String.fromUtf8(data[ls + baseIndent..le])
            }
            lines.add(content)
            trailingBlanks = 0
            pos = if (le < end) { le + 1 } else { le }
        }
        // 移除内容后的尾部空行（按剥离/裁剪处理；保留指示符不删）
        var total = lines.size
        if (chomp <= 0) {
            total -= trailingBlanks
        }
        if (total < 0) {
            total = 0
        }
        // 组装：> 折叠单个换行为空格（空行保留为换行）
        let body = StringBuilder()
        var prevBlank = false
        var first = true
        var idx: Int64 = 0
        while (idx < total) {
            let line = lines[idx]
            if (first) {
                first = false
                body.append(line)
            } else if (marker == 62 && line != "" && !prevBlank) {
                body.append(" ")
                body.append(line)
            } else {
                body.append("\n")
                if (line != "" || prevBlank) {
                    body.append(line)
                }
            }
            prevBlank = line == ""
            idx += 1
        }
        // 尾换行：剥离无、裁剪单个；保留指示符的全部尾换行由内容行与本次追加共同构成
        if (chomp >= 0 && total > 0) {
            body.append("\n")
        }
        ObjText(body.toString(), escaped: false, span: Span(s, pos), formatTag: "yaml:block")
    }

    func parseFlowMap(): ?Obj {
        let s = pos
        let map = ObjMap(span: Span(s, s), formatTag: "yaml:flow", ref: None)
        pos += 1
        while (pos < end) {
            skipFlowWs()
            if (pos >= end) {
                return None
            }
            if (data[pos] == 125) {
                pos += 1
                map.span = Span(s, pos)
                return Some(map)
            }
            // 键
            let keyNode = parseFlowScalarPart()
            if (let None <- keyNode) {
                return None
            }
            let key = keyText(keyNode.getOrThrow())
            skipFlowWs()
            var value: Obj = ObjNull(span: Span(pos, pos), ref: None)
            if (pos < end && data[pos] == 58) {
                pos += 1
                skipFlowWs()
                if (pos < end && data[pos] != 44 && data[pos] != 125) {
                    if (let Some(v) <- parseFlowScalarPart()) {
                        value = v
                    } else {
                        return None
                    }
                }
            }
            map.put(key, value)
            skipFlowWs()
            if (pos < end && data[pos] == 44) {
                pos += 1
            }
        }
        None
    }

    func parseFlowSeq(): ?Obj {
        let s = pos
        let seq = ObjSeq(span: Span(s, s), formatTag: "yaml:flow", ref: None)
        pos += 1
        while (pos < end) {
            skipFlowWs()
            if (pos >= end) {
                return None
            }
            if (data[pos] == 93) {
                pos += 1
                seq.span = Span(s, pos)
                return Some(seq)
            }
            if (let Some(v) <- parseFlowScalarPart()) {
                seq.add(v)
            } else {
                return None
            }
            skipFlowWs()
            if (pos < end && data[pos] == 44) {
                pos += 1
            }
        }
        None
    }

    func skipFlowWs(): Unit {
        while (pos < end && (data[pos] == 32 || data[pos] == 9 || data[pos] == 10 || data[pos] == 13)) {
            pos += 1
        }
    }

    /// 流内标量片段（供键解析）。
    func parseFlowScalarPart(): ?Obj {
        if (pos >= end) {
            return None
        }
        let b = data[pos]
        if (b == 34) {
            if (let Some((raw, s, e)) <- readDoubleQuoted()) {
                return Some(ObjText(raw, escaped: true, span: Span(s, e), ref: None))
            }
            return None
        }
        if (b == 39) {
            if (let Some((raw, s, e)) <- readSingleQuoted()) {
                return Some(ObjText(raw, escaped: false, span: Span(s, e), ref: None))
            }
            return None
        }
        if (b == 123) {
            return parseFlowMap()
        }
        if (b == 91) {
            return parseFlowSeq()
        }
        let s = pos
        while (pos < end && data[pos] != 58 && data[pos] != 44 && data[pos] != 125 && data[pos] != 93 &&
               data[pos] != 10 && data[pos] != 32) {
            pos += 1
        }
        if (pos == s) {
            return None
        }
        Some(scalarNode(s, pos))
    }

    func keyText(node: Obj): String {
        if (let Some(t) <- node.asText()) {
            return t
        }
        node.rawText()
    }

    func readDoubleQuoted(): ?(String, Int64, Int64) {
        let s = pos
        pos += 1
        while (pos < end) {
            let b = data[pos]
            if (b == 92) {
                pos += 2
                continue
            }
            if (b == 34) {
                pos += 1
                return Some((String.fromUtf8(data[s + 1..pos - 1]), s, pos))
            }
            pos += 1
        }
        None
    }

    func readSingleQuoted(): ?(String, Int64, Int64) {
        let s = pos
        pos += 1
        while (pos < end) {
            let b = data[pos]
            if (b == 39) {
                if (pos + 1 < end && data[pos + 1] == 39) {
                    pos += 2
                    continue
                }
                pos += 1
                return Some((String.fromUtf8(data[s + 1..pos - 1]), s, pos))
            }
            pos += 1
        }
        None
    }

    /// 标量节点：Core Schema 推断类型（null/bool/int/float/text），保留原文。
    func scalarNode(s: Int64, e: Int64): Obj {
        let raw = String.fromUtf8(data[s..e])
        if (raw.size >= 2 && raw[0] == 34 && raw[raw.size - 1] == 34) {
            return ObjText(raw[1..raw.size - 1], escaped: true, span: Span(s, e), formatTag: "text", ref: None)
        }
        if (raw.size >= 2 && raw[0] == 39 && raw[raw.size - 1] == 39) {
            return ObjText(raw[1..raw.size - 1], escaped: false, span: Span(s, e), formatTag: "text", ref: None)
        }
        // Core Schema
        if (raw == "null" || raw == "Null" || raw == "NULL" || raw == "~" || raw.isEmpty()) {
            return ObjNull(span: Span(s, e), formatTag: "yaml:null", ref: None)
        }
        if (raw == "true" || raw == "True" || raw == "TRUE") {
            return ObjBool(true, span: Span(s, e), formatTag: "yaml:bool", ref: None)
        }
        if (raw == "false" || raw == "False" || raw == "FALSE") {
            return ObjBool(false, span: Span(s, e), formatTag: "yaml:bool", ref: None)
        }
        let body = if (raw.startsWith("0x")) {
            raw[2..raw.size]
        } else if (raw.startsWith("0o")) {
            raw[2..raw.size]
        } else {
            raw
        }
        if (let Some(i) <- parseInt64(body)) {
            return ObjNumber(raw, span: Span(s, e), formatTag: "yaml:int", ref: None)
        }
        if (let Some(f) <- parseFloat64(body)) {
            return ObjNumber(raw, span: Span(s, e), formatTag: "yaml:float", ref: None)
        }
        ObjText(raw, escaped: false, span: Span(s, e), formatTag: "yaml:str", ref: None)
    }

    /// 去掉引号的标量原文（键用）。
    func unquoteScalar(raw: String): String {
        if (raw.size >= 2) {
            let bs = raw.toArray()
            if (bs[0] == 34 && bs[bs.size - 1] == 34) {
                return String.fromUtf8(bs[1..bs.size - 1])
            }
            if (bs[0] == 39 && bs[bs.size - 1] == 39) {
                return String.fromUtf8(bs[1..bs.size - 1])
            }
        }
        raw
    }
}

/// 行内是否含 "key:" 形状（键后紧跟冒号+空格/行尾），供多行纯标量续行判断。
internal func findKeyColonIn(line: String): Bool {
    let bs = line.toArray()
    var i: Int64 = 0
    var inQ: UInt8 = 0
    while (i < bs.size) {
        let b = bs[i]
        if (inQ != 0) {
            if (b == inQ) {
                inQ = 0
            } else if (b == 92 && inQ == 34) {
                i += 1
            }
        } else if (b == 34 || b == 39) {
            inQ = b
        } else if (b == 58) { // ':'
            if (i + 1 >= bs.size || bs[i + 1] == 32 || bs[i + 1] == 9) {
                return true
            }
        }
        i += 1
    }
    false
}
