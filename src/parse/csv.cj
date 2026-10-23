// CSV 解析器：引号字段、转义引号、自动分隔符（逗号/分号/制表符）、可选表头。
package rawprism.parse

import rawprism.core.*
import rawprism.object.*
import std.collection.*

public class CsvResult {
    public let rows: ArrayList<ObjSeq>
    public let header: ArrayList<String>
    public let ok: Bool
    public let errorPos: Int64
    public let errorMessage: String

    public init(rows: ArrayList<ObjSeq>, header: ArrayList<String>,
                ok!: Bool = true, errorPos!: Int64 = -1, errorMessage!: String = "") {
        this.rows = rows
        this.header = header
        this.ok = ok
        this.errorPos = errorPos
        this.errorMessage = errorMessage
    }
}

/// CSV 解析行数据（内部）。
public class CsvRowData {
    public let cells: ArrayList<(String, Span)>
    public var span: Span

    public init(span: Span) {
        this.cells = ArrayList<(String, Span)>()
        this.span = span
    }
}

/// CSV 解析入口。
public func parseCsv(data: Array<UInt8>, start!: Int64 = 0, end!: Int64 = -1,
                     delimiter!: UInt8 = 0, hasHeader!: ?Bool = None,
                     limits!: ParseLimits = ParseLimits()): CsvResult {
    let _ = limits
    var e = end
    if (e < 0) {
        e = data.size
    }
    var sep = delimiter
    if (sep == 0) {
        sep = detectCsvDelimiter(data, start, e)
    }
    let rows = ArrayList<CsvRowData>()
    var i = start
    var rowStart = start
    var cellStart = start
    var cur = CsvRowData(Span(start, start))
    var inQuotes = false
    while (i < e) {
        let b = data[i]
        if (inQuotes) {
            if (b == 34) { // '"'
                if (i + 1 < e && data[i + 1] == 34) {
                    i += 2
                    continue
                }
                inQuotes = false
            }
            i += 1
            continue
        }
        if (b == 34) {
            inQuotes = true
            i += 1
            continue
        }
        if (b == sep) {
            cur.cells.add((csvCellText(data, cellStart, i), Span(cellStart, i)))
            i += 1
            cellStart = i
            continue
        }
        if (b == 10) { // '\n'
            var rowEnd = i
            if (rowEnd > rowStart && data[rowEnd - 1] == 13) {
                rowEnd -= 1
            }
            var cellEnd = i
            if (cellEnd > cellStart && data[cellEnd - 1] == 13) {
                cellEnd -= 1
            }
            cur.cells.add((csvCellText(data, cellStart, cellEnd), Span(cellStart, cellEnd)))
            cur.span = Span(rowStart, rowEnd)
            rows.add(cur)
            i += 1
            rowStart = i
            cellStart = i
            cur = CsvRowData(Span(i, i))
            continue
        }
        i += 1
    }
    // 最后一行
    if (cellStart < e || cur.cells.size > 0) {
        var cellEnd = e
        if (cellEnd > cellStart && data[cellEnd - 1] == 13) {
            cellEnd -= 1
        }
        cur.cells.add((csvCellText(data, cellStart, cellEnd), Span(cellStart, cellEnd)))
        cur.span = Span(rowStart, e)
        // 只有整行全空时才跳过
        var allEmpty = cur.cells.size <= 1
        if (allEmpty && cur.cells.size == 1) {
            allEmpty = cur.cells[0][0].isEmpty()
        }
        if (!allEmpty) {
            rows.add(cur)
        }
    }
    if (inQuotes) {
        return CsvResult(ArrayList<ObjSeq>(), ArrayList<String>(),
            ok: false, errorPos: e, errorMessage: "CSV 引号未闭合")
    }
    if (rows.size == 0) {
        return CsvResult(ArrayList<ObjSeq>(), ArrayList<String>())
    }
    // 表头判断
    var headerMode = false
    if (let Some(h) <- hasHeader) {
        headerMode = h
    } else {
        headerMode = looksLikeHeader(rows)
    }
    if (headerMode) {
        let headerRow = rows[0]
        let headerNames = ArrayList<String>()
        for ((name, _) in headerRow.cells) {
            headerNames.add(name)
        }
        return CsvResult(convertCsvRows(rows, 1), headerNames)
    }
    return CsvResult(convertCsvRows(rows, 0), ArrayList<String>())
}

/// 单元格文本：剥离引号并反转义 "" -> "。
public func csvCellText(data: Array<UInt8>, s: Int64, e: Int64): String {
    var bs = s
    var be = e
    if (be > bs && data[bs] == 34 && data[be - 1] == 34) {
        let inner = StringBuilder()
        var i = bs + 1
        while (i < be - 1) {
            if (data[i] == 34 && i + 1 < be - 1 && data[i + 1] == 34) {
                inner.append("\"")
                i += 2
                continue
            }
            inner.append(String.fromUtf8([data[i]]))
            i += 1
        }
        return inner.toString()
    }
    if (be > bs) {
        return String.fromUtf8(data[bs..be])
    }
    ""
}

/// 分隔符探测：首行中逗号/分号/制表符出现最多者。
public func detectCsvDelimiter(data: Array<UInt8>, start: Int64, end: Int64): UInt8 {
    var commas: Int64 = 0
    var semis: Int64 = 0
    var tabs: Int64 = 0
    var i = start
    var inQuotes = false
    while (i < end && data[i] != 10) {
        let b = data[i]
        if (inQuotes) {
            if (b == 34) {
                inQuotes = false
            }
        } else if (b == 34) {
            inQuotes = true
        } else if (b == 44) {
            commas += 1
        } else if (b == 59) {
            semis += 1
        } else if (b == 9) {
            tabs += 1
        }
        i += 1
    }
    if (tabs >= commas && tabs >= semis && tabs > 0) {
        return 9
    }
    if (semis > commas) {
        return 59
    }
    44
}

/// 启发式表头判断：首行全部单元格非空且不含纯数字。
public func looksLikeHeader(rows: ArrayList<CsvRowData>): Bool {
    let first = rows[0]
    if (first.cells.size == 0) {
        return false
    }
    for ((cell, _) in first.cells) {
        let t = cell.trimAscii()
        if (t.isEmpty()) {
            return false
        }
        if (let Some(_) <- parseInt64(t)) {
            return false
        }
        if (let Some(_) <- parseFloat64(t)) {
            return false
        }
    }
    true
}

/// 把行数据转成 ObjSeq；有表头时在会话层转映射。
internal func convertCsvRows(rows: ArrayList<CsvRowData>, from: Int64): ArrayList<ObjSeq> {
    let out = ArrayList<ObjSeq>()
    var i = from
    while (i < rows.size) {
        let row = rows[i]
        let seq = ObjSeq(span: row.span, formatTag: "csv:row", ref: None)
        for ((cell, sp) in row.cells) {
            let v = inferCsvScalar(cell, sp)
            seq.add(v)
        }
        out.add(seq)
        i += 1
    }
    out
}

/// CSV 单元格标量推断：数字/布尔，否则文本。
public func inferCsvScalar(cell: String, sp: Span): Obj {
    let t = cell.trimAscii()
    if (t == "true") {
        return ObjBool(true, span: sp, formatTag: "csv:bool", ref: None)
    }
    if (t == "false") {
        return ObjBool(false, span: sp, formatTag: "csv:bool", ref: None)
    }
    if (t.size > 0 && isAllDigits(t)) {
        if (let Some(i) <- parseInt64(t)) {
            return ObjNumber(t, span: sp, formatTag: "csv:int", ref: None)
        }
    }
    if (t.size > 0 && isNumericLike(t)) {
        if (let Some(f) <- parseFloat64(t)) {
            return ObjNumber(t, span: sp, formatTag: "csv:float", ref: None)
        }
    }
    ObjText(cell, escaped: false, span: sp, formatTag: "csv:text", ref: None)
}

public func isAllDigits(s: String): Bool {
    if (s.isEmpty()) {
        return false
    }
    for (b in s.toArray()) {
        if (b < 48 || b > 57) {
            return false
        }
    }
    true
}

public func isNumericLike(s: String): Bool {
    if (s.isEmpty()) {
        return false
    }
    var seenDigit = false
    for (b in s.toArray()) {
        if (b >= 48 && b <= 57) {
            seenDigit = true
        } else if (b == 46 || b == 45 || b == 43 || b == 101 || b == 69) {
            // 分隔符
        } else {
            return false
        }
    }
    seenDigit
}
