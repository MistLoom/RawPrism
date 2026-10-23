// Markdown 结构识别：front matter、标题、段落、围栏代码块（语言参数）、
// 缩进代码块、表格、HTML 块、链接语法位置（供实体登记）。
package rawprism.parse

import rawprism.core.*
import std.collection.*

/// Markdown 块。
public class MdBlock {
    public let kind: String      // "frontmatter" | "heading" | "paragraph" | "code" | "table" | "html" | "list"
    public let span: Span
    /// heading 层级（1-6）；code 语言；其余为 ""。
    public let param: String
    /// 行首内容偏移（去掉标记符 #、``` 等）。
    public let contentSpan: Span
    /// 代码块的原文内容区间（围栏内）。
    public let codeSpan: Span
    /// 链接语法区间列表：(文本区间, 目标区间)。
    public let links: ArrayList<(Span, Span)>

    public init(kind: String, span: Span, param!: String = "", contentSpan!: Span = Span(0, 0),
                codeSpan!: Span = Span(0, 0)) {
        this.kind = kind
        this.span = span
        this.param = param
        this.contentSpan = contentSpan
        this.codeSpan = codeSpan
        this.links = ArrayList<(Span, Span)>()
    }
}

public class MdResult {
    public let blocks: ArrayList<MdBlock>
    /// front matter 内部区间（不含定界行），无则 None。
    public let frontMatter: Option<Span>

    public init(blocks: ArrayList<MdBlock>, frontMatter: Option<Span>) {
        this.blocks = blocks
        this.frontMatter = frontMatter
    }
}

/// Markdown 块级结构识别。
public func parseMarkdownBlocks(data: Array<UInt8>, start!: Int64 = 0, end!: Int64 = -1): MdResult {
    var e = end
    if (e < 0) {
        e = data.size
    }
    let blocks = ArrayList<MdBlock>()
    var fm: Option<Span> = None
    var i = start
    // front matter
    if (lineStartsWith(data, i, e, "---")) {
        let fmStart = i
        var j = lineEnd(data, i, e) + 1
        var found = false
        while (j < e) {
            if (lineStartsWith(data, j, e, "---") || lineStartsWith(data, j, e, "...")) {
                let fmEnd = lineEnd(data, j, e)
                let bodyStart = lineEnd(data, fmStart, e) + 1
                let bodyEnd = if (j > bodyStart && data[j - 1] == 10) { j - 1 } else { j }
                let blk = MdBlock("frontmatter", Span(fmStart, fmEnd), contentSpan: Span(bodyStart, bodyEnd))
                blocks.add(blk)
                fm = Some(Span(bodyStart, bodyEnd))
                i = if (fmEnd < e) { fmEnd + 1 } else { e }
                found = true
                break
            }
            j = lineEnd(data, j, e) + 1
        }
        if (!found) {
            // 未闭合 front matter：按普通文本处理（不定界）
            i = fmStart
        }
    }
    // 逐块
    while (i < e) {
        // 跳过空行
        while (i < e) {
            var le = lineEnd(data, i, e)
            var onlyBlank = true
            var k = i
            while (k < le) {
                if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                    onlyBlank = false
                    break
                }
                k += 1
            }
            if (!onlyBlank) {
                break
            }
            i = if (le < e) { le + 1 } else { e }
        }
        if (i >= e) {
            break
        }
        let lineInd = indentOfMd(data, i)
        // 围栏代码块 ``` 或 ~~~
        if ((data[i + lineInd] == 96 || data[i + lineInd] == 126) && fenceRun(data, i + lineInd, e) >= 3) {
            let r = parseFencedCode(data, i, e)
            blocks.add(r[0])
            i = r[1]
            continue
        }
        // 标题 # 
        if (data[i + lineInd] == 35) {
            var hashes: Int64 = 0
            var k = i + lineInd
            while (k < e && data[k] == 35) {
                hashes += 1
                k += 1
            }
            if (hashes <= 6 && (k >= e || data[k] == 32 || data[k] == 9 || data[k] == 13)) {
                let le = lineEnd(data, i, e)
                let blk = MdBlock("heading", Span(i, le), param: headingLevel(hashes),
                    contentSpan: Span(i + lineInd + hashes, le))
                collectMdLinks(data, blk.contentSpan, blk)
                blocks.add(blk)
                i = if (le < e) { le + 1 } else { e }
                continue
            }
        }
        // HTML 块：行首是 '<' 且像标签
        if (data[i + lineInd] == 60 && looksLikeHtmlBlock(data, i + lineInd, e)) {
            let r = parseHtmlBlock(data, i, e)
            blocks.add(r[0])
            i = r[1]
            continue
        }
        // 表格：当前行含 | 且下一行是分隔行 |---|---|
        if (isTableStart(data, i, e)) {
            let r = parseTable(data, i, e)
            blocks.add(r[0])
            i = r[1]
            continue
        }
        // 缩进代码块：4 空格以上
        if (lineInd >= 4) {
            let blockStart = i
            var last = i
            var j = i
            while (j < e) {
                let le = lineEnd(data, j, e)
                var blank = true
                var k = j
                while (k < le) {
                    if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                        blank = false
                        break
                    }
                    k += 1
                }
                if (blank) {
                    // 空行可能是代码块的一部分；看下一行
                    if (le >= e) {
                        last = le
                        j = e
                        break
                    }
                    j = le + 1
                    continue
                }
                if (indentOfMd(data, j) >= 4) {
                    last = le
                    j = if (le < e) { le + 1 } else { e }
                    continue
                }
                break
            }
            let contentStart = blockStart + 4
            let blk = MdBlock("code", Span(blockStart, last), param: "",
                codeSpan: Span(contentStart, last))
            blocks.add(blk)
            i = last
            if (i < e && data[i] == 10) {
                i += 1
            }
            continue
        }
        // 段落：连续非空行，直到空行或结构块开始
        let paraStart = i
        var paraEnd = i
        var j = i
        while (j < e) {
            let le = lineEnd(data, j, e)
            var blank = true
            var k = j
            while (k < le) {
                if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                    blank = false
                    break
                }
                k += 1
            }
            if (blank) {
                break
            }
            let ind = indentOfMd(data, j)
            // 结构块开始则段落结束
            if (j > paraStart) {
                let c = data[j + ind]
                if ((c == 96 || c == 126) && fenceRun(data, j + ind, e) >= 3) {
                    break
                }
                if (c == 35) {
                    break
                }
                if (c == 60 && looksLikeHtmlBlock(data, j + ind, e)) {
                    break
                }
            }
            paraEnd = le
            j = if (le < e) { le + 1 } else { e }
        }
        let blk = MdBlock("paragraph", Span(paraStart, paraEnd), contentSpan: Span(paraStart, paraEnd))
        collectMdLinks(data, blk.contentSpan, blk)
        blocks.add(blk)
        i = paraEnd
        if (i < e && data[i] == 10) {
            i += 1
        }
    }
    MdResult(blocks, fm)
}

internal func headingLevel(hashes: Int64): String {
    "h${hashes}"
}

internal func indentOfMd(data: Array<UInt8>, p: Int64): Int64 {
    var i = p
    var n: Int64 = 0
    while (i < data.size && data[i] == 32) {
        n += 1
        i += 1
    }
    n
}

/// 围栏连续字符数。
internal func fenceRun(data: Array<UInt8>, p: Int64, end: Int64): Int64 {
    let c = data[p]
    var n: Int64 = 0
    var i = p
    while (i < end && data[i] == c) {
        n += 1
        i += 1
    }
    n
}

/// 解析围栏代码块。返回 (块, 下一位置)。
internal func parseFencedCode(data: Array<UInt8>, start: Int64, end: Int64): (MdBlock, Int64) {
    let ind = indentOfMd(data, start)
    let fenceStart = start + ind
    let marker = data[fenceStart]
    let openRun = fenceRun(data, fenceStart, end)
    // 语言
    var j = fenceStart + openRun
    while (j < end && data[j] == 32) {
        j += 1
    }
    let infoStart = j
    var le = lineEnd(data, start, end)
    var lang = ""
    if (j < le) {
        lang = toLowerAscii(trimAscii(String.fromUtf8(data[infoStart..le])))
    }
    // 内容到匹配的闭合围栏
    var i = if (le < end) { le + 1 } else { end }
    let contentStart = i
    var contentEnd = i
    while (i < end) {
        let li = indentOfMd(data, i)
        if (data[i + li] == marker && fenceRun(data, i + li, end) >= openRun) {
            let closeLine = lineEnd(data, i, end)
            // 闭合行必须只有围栏（可含空白）
            var onlyFence = true
            var k = i + li + fenceRun(data, i + li, end)
            while (k < closeLine) {
                if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                    onlyFence = false
                    break
                }
                k += 1
            }
            if (onlyFence) {
                contentEnd = if (i > contentStart && data[i - 1] == 10) { i - 1 } else { i }
                let blk = MdBlock("code", Span(start, closeLine), param: lang,
                    codeSpan: Span(contentStart, contentEnd))
                let next = if (closeLine < end) { closeLine + 1 } else { end }
                return (blk, next)
            }
        }
        i = if (lineEnd(data, i, end) < end) { lineEnd(data, i, end) + 1 } else { end }
    }
    // 未闭合：内容到末尾
    let blk = MdBlock("code", Span(start, end), param: lang, codeSpan: Span(contentStart, end))
    return (blk, end)
}

/// HTML 块：从开始标签行到空行（简化规则）。
internal func looksLikeHtmlBlock(data: Array<UInt8>, p: Int64, end: Int64): Bool {
    // '<' 后是字母或 '/' 或 '!'
    if (p + 1 >= end) {
        return false
    }
    let b = data[p + 1]
    if ((b >= 97 && b <= 122) || (b >= 65 && b <= 90) || b == 47 || b == 33) {
        return true
    }
    false
}

internal func parseHtmlBlock(data: Array<UInt8>, start: Int64, end: Int64): (MdBlock, Int64) {
    // HTML 块延伸到空行或输入结束
    let blockStart = start
    var i = start
    var blockEnd = start
    while (i < end) {
        let le = lineEnd(data, i, end)
        var blank = true
        var k = i
        while (k < le) {
            if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                blank = false
                break
            }
            k += 1
        }
        if (blank) {
            break
        }
        blockEnd = le
        i = if (le < end) { le + 1 } else { end }
    }
    (MdBlock("html", Span(blockStart, blockEnd), contentSpan: Span(blockStart, blockEnd)),
        if (blockEnd < end) { blockEnd + 1 } else { end })
}

/// 表格开始判断：当前行含 '|' 且下一行（非空）是分隔行。
internal func isTableStart(data: Array<UInt8>, p: Int64, end: Int64): Bool {
    var hasPipe = false
    var i = p
    let le = lineEnd(data, p, end)
    while (i < le) {
        if (data[i] == 124) {
            hasPipe = true
            break
        }
        i += 1
    }
    if (!hasPipe) {
        return false
    }
    var j = if (le < end) { le + 1 } else { end }
    if (j >= end) {
        return false
    }
    let le2 = lineEnd(data, j, end)
    // 分隔行：只含 |、-、:、空白
    var k = j
    var seenDash = false
    var seenOther = false
    while (k < le2) {
        let b = data[k]
        if (b == 45) {
            seenDash = true
        } else if (b == 124 || b == 58 || b == 32 || b == 9 || b == 13) {
            // 允许
        } else {
            seenOther = true
            break
        }
        k += 1
    }
    seenDash && !seenOther
}

/// 解析表格（含表头与分隔行）。
internal func parseTable(data: Array<UInt8>, start: Int64, end: Int64): (MdBlock, Int64) {
    let blockStart = start
    var i = start
    var blockEnd = start
    var rows: Int64 = 0
    while (i < end) {
        let le = lineEnd(data, i, end)
        var blank = true
        var k = i
        while (k < le) {
            if (data[k] != 32 && data[k] != 9 && data[k] != 13) {
                blank = false
                break
            }
            k += 1
        }
        if (blank) {
            break
        }
        // 行内必须有 |（否则表格结束）
        var hasPipe = false
        var m = i
        while (m < le) {
            if (data[m] == 124) {
                hasPipe = true
                break
            }
            m += 1
        }
        if (!hasPipe && rows >= 2) {
            break
        }
        blockEnd = le
        rows += 1
        i = if (le < end) { le + 1 } else { end }
    }
    (MdBlock("table", Span(blockStart, blockEnd), contentSpan: Span(blockStart, blockEnd)),
        if (blockEnd < end) { blockEnd + 1 } else { end })
}

/// 收集段落/标题内的链接语法区间：[text](target) 与 <url>。
internal func collectMdLinks(data: Array<UInt8>, s: Span, blk: MdBlock): Unit {
    var i = s.start
    while (i < s.end - 1) {
        // [text](target)
        if (data[i] == 91) { // '['
            // 找 ']('
            var j = i + 1
            var depth = 1
            var textEnd = -1
            while (j < s.end) {
                let b = data[j]
                if (b == 92) { // 转义
                    j += 2
                    continue
                }
                if (b == 91) {
                    depth += 1
                } else if (b == 93) {
                    depth -= 1
                    if (depth == 0) {
                        textEnd = j
                        break
                    }
                }
                j += 1
            }
            if (textEnd > 0 && textEnd + 1 < s.end && data[textEnd + 1] == 40) {
                // 找 ')'
                var k = textEnd + 2
                var pdepth = 1
                var targetEnd = -1
                while (k < s.end) {
                    let b = data[k]
                    if (b == 40) {
                        pdepth += 1
                    } else if (b == 41) {
                        pdepth -= 1
                        if (pdepth == 0) {
                            targetEnd = k
                            break
                        }
                    }
                    k += 1
                }
                if (targetEnd > 0) {
                    let textSpan = Span(i + 1, textEnd)
                    let targetSpan = Span(textEnd + 2, targetEnd)
                    blk.links.add((textSpan, targetSpan))
                    i = targetEnd
                    continue
                }
            }
        }
        // <url>
        if (data[i] == 60) {
            var k = i + 1
            while (k < s.end && data[k] != 62) {
                if (data[k] == 32 || data[k] == 10) {
                    break
                }
                k += 1
            }
            if (k < s.end && data[k] == 62 && k > i + 1) {
                let inner = String.fromUtf8(data[i + 1..k])
                if (looksLikeUrlText(inner)) {
                    blk.links.add((Span(i + 1, k), Span(i + 1, k)))
                    i = k
                    continue
                }
            }
        }
        i += 1
    }
}

/// 裸 URL 文本形状判断（scheme: 前缀）。
public func looksLikeUrlText(s: String): Bool {
    let bs = s.toArray()
    var i: Int64 = 0
    var seenAlpha = false
    while (i < bs.size) {
        let b = bs[i]
        if ((b >= 97 && b <= 122) || (b >= 65 && b <= 90)) {
            seenAlpha = true
            i += 1
            continue
        }
        if (b == 43 || b == 45 || b == 46) {
            i += 1
            continue
        }
        if (b == 58 && seenAlpha) {
            // scheme 后不能紧跟空格
            return i + 1 < bs.size && bs[i + 1] != 32
        }
        return false
    }
    false
}
