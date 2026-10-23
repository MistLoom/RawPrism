// JSONPath 查询（RFC 9535）：
// $ 根；.key / ['key'] 子节点；.* / [*] 通配；..key / ..[*] / ..[?(...)] 递归下降；
// [n] 下标；[n,m] 与 ['a',0] 混合并集；[start:end:step] 切片；
// 过滤器 [?(...)]：逻辑 && / || / ! / 括号，比较 == != < <= > >=，
// 比较双方可为字面量、单一查询（@ / $）、RFC 9535 标准函数
// length() / count() / match() / search() / value()。
package rawprism.object

import std.collection.*
import std.regex.*
import rawprism.core.*

/// 路径段种类。
public enum PathSegKind {
    | PSRoot
    | PSChild      // 按键
    | PSWildcard   // .* 或 [*]
    | PSIndex      // [n]
    | PSUnion      // [n,m] / ['a','b'] / 混合
    | PSSlice      // [start:end:step]
    | PSRecursive  // ..key / ..* / ..[?]：对每个后代应用 inner
    | PSFilter     // [?(...)]
}

/// 路径段（class 以支持 ..[?] 的递归嵌套）。
public class PathSeg {
    public let kind: PathSegKind
    public let key: String
    /// 混合并集成员（isName ? name : index）。
    public let unionItems: ArrayList<(Bool, String, Int64)>
    public let start: Int64
    public let end: Int64
    public let step: Int64
    public let hasSlice: Bool
    /// 过滤表达式 AST。
    public let filterAst: Option<FNode>
    /// 递归段内嵌段（..[inner] / ..key 的 inner 为 child(key)）。
    public let inner: Option<PathSeg>

    public init(kind: PathSegKind, key!: String = "", unionItems!: ArrayList<(Bool, String, Int64)> = ArrayList<(Bool, String, Int64)>(),
                start!: Int64 = 0, end!: Int64 = Int64.Max, step!: Int64 = 1, hasSlice!: Bool = false,
                filterAst!: Option<FNode> = None, inner!: Option<PathSeg> = None) {
        this.kind = kind
        this.key = key
        this.unionItems = unionItems
        this.start = start
        this.end = end
        this.step = step
        this.hasSlice = hasSlice
        this.filterAst = filterAst
        this.inner = inner
    }
}

// ---------- 过滤表达式 AST（RFC 9535） ----------

/// 过滤表达式节点。
public abstract class FNode {}

/// 逻辑与。
public class FAnd <: FNode {
    public let left: FNode
    public let right: FNode
    public init(left: FNode, right: FNode) {
        this.left = left
        this.right = right
    }
}

/// 逻辑或。
public class FOr <: FNode {
    public let left: FNode
    public let right: FNode
    public init(left: FNode, right: FNode) {
        this.left = left
        this.right = right
    }
}

/// 逻辑非。
public class FNot <: FNode {
    public let inner: FNode
    public init(inner: FNode) {
        this.inner = inner
    }
}

/// 函数作为布尔操作数（match / search）。
public class FFuncBool <: FNode {
    public let call: OFunc
    public init(call: OFunc) {
        this.call = call
    }
}

/// 比较表达式。
public class FCmp <: FNode {
    public let op: String
    public let left: FOperand
    public let right: FOperand
    public init(op: String, left: FOperand, right: FOperand) {
        this.op = op
        this.left = left
        this.right = right
    }
}

/// 存在性测试（单一查询非 Nothing）。
public class FExists <: FNode {
    public let path: FPath
    public init(path: FPath) {
        this.path = path
    }
}

/// 过滤器中的查询：@ 相对 / $ 绝对。
public class FPath {
    public let fromRoot: Bool
    public let segs: Array<PathSeg>
    public init(fromRoot: Bool, segs: Array<PathSeg>) {
        this.fromRoot = fromRoot
        this.segs = segs
    }
}

/// 比较操作数。
public abstract class FOperand {}

/// 查询操作数。
public class OPath <: FOperand {
    public let path: FPath
    public init(path: FPath) {
        this.path = path
    }
}

/// 字符串字面量。
public class OText <: FOperand {
    public let value: String
    public init(value: String) {
        this.value = value
    }
}

/// 数字字面量。
public class ONum <: FOperand {
    public let raw: String
    public init(raw: String) {
        this.raw = raw
    }
}

/// 布尔字面量。
public class OBool <: FOperand {
    public let value: Bool
    public init(value: Bool) {
        this.value = value
    }
}

/// null 字面量。
public class ONullLit <: FOperand {
    public init() {}
}

/// 函数调用操作数（RFC 9535：length / count / match / search / value）。
public class OFunc <: FOperand {
    public let name: String
    public let args: Array<FOperand>
    public init(name: String, args: Array<FOperand>) {
        this.name = name
        this.args = args
    }
}

/// 从查询字符串解析段序列（可带或不带前导 $）。
public func parsePath(q: String): Array<PathSeg> {
    let bs = q.toArray()
    var i: Int64 = 0
    if (i < bs.size && bs[i] == 36) { // '$'
        i += 1
    }
    let r = parseSegsAt(bs, i, bs.size)
    r[0]
}

/// 从 bs[i] 起解析段序列，返回 (段列表, 结束位置)。
/// 段种类相等判断（枚举不支持 ==）。
internal func segKindEq(a: PathSegKind, b: PathSegKind): Bool {
    match (a) {
        case PSRoot => match (b) { case PSRoot => true; case _ => false }
        case PSChild => match (b) { case PSChild => true; case _ => false }
        case PSWildcard => match (b) { case PSWildcard => true; case _ => false }
        case PSIndex => match (b) { case PSIndex => true; case _ => false }
        case PSUnion => match (b) { case PSUnion => true; case _ => false }
        case PSSlice => match (b) { case PSSlice => true; case _ => false }
        case PSRecursive => match (b) { case PSRecursive => true; case _ => false }
        case PSFilter => match (b) { case PSFilter => true; case _ => false }
    }
}

internal func parseSegsAt(bs: Array<UInt8>, start: Int64, n: Int64, inFilter!: Bool = false): (Array<PathSeg>, Int64) {
    let out = ArrayList<PathSeg>()
    var i = start
    while (i < n) {
        let b = bs[i]
        if (inFilter && isFilterStop(b)) {
            break
        }
        if (b == 46) { // '.'
            i += 1
            if (i < n && bs[i] == 46) { // '..' 递归下降
                i += 1
                if (i < n && bs[i] == 42) { // ..*
                    out.add(PathSeg(PSRecursive, key: "*", inner: Some(PathSeg(PSWildcard))))
                    i += 1
                    continue
                }
                if (i < n && bs[i] == 91) { // ..[...]
                    let r = parseBracketAt(bs, i, n)
                    out.add(PathSeg(PSRecursive, inner: Some(r[0])))
                    i = r[1]
                    continue
                }
                var j = i
                while (j < n && bs[j] != 46 && bs[j] != 91 && !(inFilter && isFilterStop(bs[j]))) {
                    j += 1
                }
                if (j > i) {
                    let key = String.fromUtf8(bs[i..j])
                    out.add(PathSeg(PSRecursive, key: key, inner: Some(PathSeg(PSChild, key: key))))
                    i = j
                }
            } else if (i < n && bs[i] == 42) { // .*
                out.add(PathSeg(PSWildcard))
                i += 1
            } else {
                var j = i
                while (j < n && bs[j] != 46 && bs[j] != 91 && !(inFilter && isFilterStop(bs[j]))) {
                    j += 1
                }
                if (j > i) {
                    out.add(PathSeg(PSChild, key: String.fromUtf8(bs[i..j])))
                }
                i = j
            }
        } else if (b == 91) { // '['
            let r = parseBracketAt(bs, i, n)
            out.add(r[0])
            i = r[1]
        } else {
            break
        }
    }
    (out.toArray(), i)
}

/// 过滤器上下文中裸名段的停止字符（运算符、空白、括号、并集/集合闭合）。
internal func isFilterStop(b: UInt8): Bool {
    b == 32 || b == 9 || b == 10 || b == 13 ||
    b == 61 || b == 33 || b == 60 || b == 62 ||  // = ! < >
    b == 40 || b == 41 || b == 44 ||             // ( ) ,
    b == 38 || b == 124 ||                        // & |
    b == 93 || b == 125                           // ] }
}

/// 解析方括号段（bs[i] 为 '['），返回 (段, ']' 后位置)。
internal func parseBracketAt(bs: Array<UInt8>, i: Int64, n: Int64): (PathSeg, Int64) {
    // 找匹配的 ']'（考虑引号）
    var j = i + 1
    var inStr: UInt8 = 0
    while (j < n) {
        let c = bs[j]
        if (inStr != 0) {
            if (c == 92 && inStr == 39) { // 单引号转义 ''
                j += 2
                continue
            }
            if (c == inStr) {
                inStr = 0
            }
        } else if (c == 39 || c == 34) {
            inStr = c
        } else if (c == 93) { // ']'
            break
        }
        j += 1
    }
    if (j >= n) {
        return (PathSeg(PSChild, key: ""), n)
    }
    let body = String.fromUtf8(bs[i + 1..j])
    let seg = parseBracketBody(body)
    return (seg, j + 1)
}

/// 解析方括号内文本。
internal func parseBracketBody(t0: String): PathSeg {
    let t = trimAscii(t0)
    if (t == "*") {
        return PathSeg(PSWildcard)
    }
    if (t.startsWith("?")) {
        var inner = t
        if (inner.startsWith("?(") && inner.endsWith(")")) {
            inner = inner[2..inner.size - 1]
        } else if (inner.startsWith("?")) {
            inner = inner[1..inner.size]
        }
        let p = FilterParser(String.fromUtf8(trimAscii(inner).toArray()))
        let ast = p.parse()
        return PathSeg(PSFilter, filterAst: ast)
    }
    if (t.contains(":")) {
        let parts = t.split(":", removeEmpty: false)
        // start/end/step 均可缺省；负步长时缺省方向反转（RFC 9535）
        var startV: Int64 = 0
        var endV: Int64 = Int64.Max
        var stepV: Int64 = 1
        var hasStart = false
        var hasEnd = false
        if (parts.size > 0 && parts[0].size > 0) {
            if (let Some(v) <- parseInt64(parts[0])) {
                startV = v
                hasStart = true
            }
        }
        if (parts.size > 1 && parts[1].size > 0) {
            if (let Some(v) <- parseInt64(parts[1])) {
                endV = v
                hasEnd = true
            }
        }
        if (parts.size > 2 && parts[2].size > 0) {
            if (let Some(v) <- parseInt64(parts[2])) {
                stepV = v
            }
        }
        var seg = PathSeg(PSSlice, start: startV, end: endV, step: stepV, hasSlice: true)
        if (!hasStart && stepV < 0) {
            // 标记：负步长下 start 缺省为数组末尾（以 Min 编码，apply 时还原）
            seg = PathSeg(PSSlice, start: Int64.Min, end: endV, step: stepV, hasSlice: true)
        }
        if (!hasEnd && stepV < 0) {
            // 标记：负步长下 end 缺省为首元素之前（以 Min 编码）
            var sv: Int64 = if (hasStart) { startV } else { Int64.Min }
            seg = PathSeg(PSSlice, start: sv, end: Int64.Min, step: stepV, hasSlice: true)
        }
        return seg
    }
    // 逗号并集：混合名称与下标
    if (t.contains(",")) {
        let items = splitUnionItems(t)
        let union = ArrayList<(Bool, String, Int64)>()
        for (it in items) {
            let s = trimAscii(it)
            if (s.size >= 2 && (s[0] == 39 || s[0] == 34)) {
                union.add((true, unquoteUnionName(s), 0))
            } else if (let Some(v) <- parseInt64(s)) {
                union.add((false, "", v))
            }
        }
        if (union.size > 0) {
            return PathSeg(PSUnion, unionItems: union)
        }
        return PathSeg(PSChild, key: "")
    }
    // 单项：名称或下标
    if (t.size >= 2 && (t[0] == 39 || t[0] == 34)) {
        return PathSeg(PSChild, key: unquoteUnionName(t))
    }
    if (let Some(v) <- parseInt64(t)) {
        let idxs = ArrayList<(Bool, String, Int64)>()
        idxs.add((false, "", v))
        return PathSeg(PSUnion, unionItems: idxs)
    }
    return PathSeg(PSChild, key: t)
}

/// 顶层逗号分割（引号外）。
internal func splitUnionItems(s: String): Array<String> {
    let out = ArrayList<String>()
    let bs = s.toArray()
    var inStr: UInt8 = 0
    var segStart: Int64 = 0
    var i: Int64 = 0
    while (i < bs.size) {
        let c = bs[i]
        if (inStr != 0) {
            if (c == 92 && inStr == 34) {
                i += 1
            } else if (c == inStr) {
                inStr = 0
            }
        } else if (c == 39 || c == 34) {
            inStr = c
        } else if (c == 44) { // ','
            out.add(String.fromUtf8(bs[segStart..i]))
            segStart = i + 1
        }
        i += 1
    }
    out.add(String.fromUtf8(bs[segStart..bs.size]))
    out.toArray()
}

/// 去掉名称选择器的引号。
internal func unquoteUnionName(s: String): String {
    if (s.size >= 2) {
        let q = s[0]
        if ((q == 39 || q == 34) && s[s.size - 1] == q) {
            return s[1..s.size - 1]
        }
    }
    s
}

/// 过滤表达式解析器（递归下降）。
internal class FilterParser {
    let bs: Array<UInt8>
    var i: Int64
    let n: Int64

    public init(s: String) {
        this.bs = s.toArray()
        this.i = 0
        this.n = this.bs.size
    }

    /// 解析整个过滤表达式；失败返回 None（该过滤器对一切节点不命中）。
    public func parse(): ?FNode {
        let e = parseOr()
        skipWs()
        if (i < n) {
            return None // 有剩余内容：表达式不完整
        }
        e
    }

    func skipWs(): Unit {
        while (i < n && (bs[i] == 32 || bs[i] == 9 || bs[i] == 10 || bs[i] == 13)) {
            i += 1
        }
    }

    func peekWord(w: String): Bool {
        let wbs = w.toArray()
        if (i + wbs.size > n) {
            return false
        }
        var k: Int64 = 0
        while (k < wbs.size) {
            if (bs[i + k] != wbs[k]) {
                return false
            }
            k += 1
        }
        true
    }

    func parseOr(): ?FNode {
        if (let Some(l) <- parseAnd()) {
            var left = l
            while (true) {
                skipWs()
                if (peekWord("||")) {
                    i += 2
                    if (let Some(r) <- parseAnd()) {
                        left = FOr(left, r)
                        continue
                    }
                    return None
                }
                if (peekWord("or") && isWordBoundaryAt(2)) {
                    i += 2
                    if (let Some(r) <- parseAnd()) {
                        left = FOr(left, r)
                        continue
                    }
                    return None
                }
                return Some(left)
            }
        }
        None
    }

    func isWordBoundaryAt(offset: Int64): Bool {
        let j = i + offset
        j >= n || !(isIdentChar(bs[j]))
    }

    func isIdentChar(b: UInt8): Bool {
        (b >= 97 && b <= 122) || (b >= 65 && b <= 90) || (b >= 48 && b <= 57) || b == 95
    }

    func parseAnd(): ?FNode {
        if (let Some(l) <- parseUnary()) {
            var left = l
            while (true) {
                skipWs()
                if (peekWord("&&")) {
                    i += 2
                    if (let Some(r) <- parseUnary()) {
                        left = FAnd(left, r)
                        continue
                    }
                    return None
                }
                if (peekWord("and") && isWordBoundaryAt(3)) {
                    i += 3
                    if (let Some(r) <- parseUnary()) {
                        left = FAnd(left, r)
                        continue
                    }
                    return None
                }
                return Some(left)
            }
        }
        None
    }

    func parseUnary(): ?FNode {
        skipWs()
        if (i < n && bs[i] == 33) { // '!'
            i += 1
            if (let Some(e) <- parseUnary()) {
                return Some(FNot(e))
            }
            return None
        }
        if (i < n && bs[i] == 40) { // '('
            i += 1
            if (let Some(e) <- parseOr()) {
                skipWs()
                if (i < n && bs[i] == 41) {
                    i += 1
                    return Some(e)
                }
            }
            return None
        }
        parsePrimary()
    }

    func parsePrimary(): ?FNode {
        skipWs()
        if (let Some(left) <- parseOperand()) {
            skipWs()
            // 尝试比较运算符
            let op = tryCompareOp()
            if (let Some(o) <- op) {
                if (let Some(right) <- parseOperand()) {
                    return Some(FCmp(o, left, right))
                }
                return None
            }
            // 无比较：存在性或布尔函数
            if (let Some(fn) <- (left as OFunc)) {
                if (fn.name == "match" || fn.name == "search") {
                    return Some(FFuncBool(fn))
                }
                return None
            }
            if (let Some(p) <- (left as OPath)) {
                return Some(FExists(p.path))
            }
            return None
        }
        None
    }

    func tryCompareOp(): ?String {
        skipWs()
        if (i < n) {
        }
        for (op in ["==", "!=", "<=", ">=", "<", ">"]) {
            if (peekWord(op)) {
                i += op.size
                return Some(op)
            }
        }
        None
    }

    func parseOperand(): ?FOperand {
        skipWs()
        if (i >= n) {
            return None
        }
        let c = bs[i]
        // 数字字面量（含正负号）：必须先于标识符分支（isIdentChar 含数字）
        if (c >= 48 && c <= 57 || ((c == 45 || c == 43) && i + 1 < n && bs[i + 1] >= 48 && bs[i + 1] <= 57)) {
            let numStart = i
            if (c == 45 || c == 43) {
                i += 1
            }
            var seenDigit = false
            while (i < n) {
                let d = bs[i]
                if (d >= 48 && d <= 57) {
                    seenDigit = true
                    i += 1
                } else if (d == 46 && i + 1 < n && bs[i + 1] >= 48 && bs[i + 1] <= 57) {
                    i += 1
                } else if ((d == 101 || d == 69) && seenDigit) {
                    i += 1
                    if (i < n && (bs[i] == 43 || bs[i] == 45)) {
                        i += 1
                    }
                } else {
                    break
                }
            }
            if (seenDigit) {
                return Some(ONum(String.fromUtf8(bs[numStart..i])))
            }
            i = numStart
            return None
        }
        // 函数或字面量单词
        if (isIdentChar(c) && c != 36 && c != 64) {
            let nameStart = i
            var j = i
            while (j < n && isIdentChar(bs[j])) {
                j += 1
            }
            let word = String.fromUtf8(bs[nameStart..j])
            if (j < n && bs[j] == 40) { // '(' 函数调用
                i = j + 1
                let args = ArrayList<FOperand>()
                while (true) {
                    skipWs()
                    if (i < n && bs[i] == 41) {
                        i += 1
                        break
                    }
                    if (let Some(a) <- parseOperand()) {
                        args.add(a)
                        skipWs()
                        if (i < n && bs[i] == 44) { // ','
                            i += 1
                            continue
                        }
                        if (i < n && bs[i] == 41) {
                            i += 1
                            break
                        }
                        return None
                    }
                    return None
                }
                return Some(OFunc(word, args.toArray()))
            }
            if (word == "true") {
                return Some(OBool(true))
            }
            if (word == "false") {
                return Some(OBool(false))
            }
            if (word == "null") {
                return Some(ONullLit())
            }
            return None
        }
        // 查询 @ / $
        if (c == 64 || c == 36) {
            let fromRoot = c == 36
            i += 1
            let r = parseSegsAt(bs, i, n, inFilter: true)
            i = r[1]
            return Some(OPath(FPath(fromRoot, r[0])))
        }
        // 字符串字面量
        if (c == 39 || c == 34) {
            let q = c
            i += 1
            let sb = StringBuilder()
            while (i < n) {
                let d = bs[i]
                if (d == 92 && q == 34 && i + 1 < n) { // 双引号反斜杠转义
                    sb.append(String.fromUtf8([bs[i + 1]]))
                    i += 2
                    continue
                }
                if (d == 92 && i + 1 < n) { // 反斜杠转义：\X -> X（正则场景保留语义）
                    sb.append(String.fromUtf8([bs[i + 1]]))
                    i += 2
                    continue
                }
                if (d == q) {
                    if (q == 39 && i + 1 < n && bs[i + 1] == 39) { // '' 转义
                        sb.append("'")
                        i += 2
                        continue
                    }
                    i += 1
                    return Some(OText(sb.toString()))
                }
                sb.append(String.fromUtf8([d]))
                i += 1
            }
            return None
        }
        // 数字字面量
        let numStart = i
        if (c == 45 || c == 43) {
            i += 1
        }
        var seenDigit = false
        while (i < n) {
            let d = bs[i]
            if (d >= 48 && d <= 57) {
                seenDigit = true
                i += 1
            } else if (d == 46 && i + 1 < n && bs[i + 1] >= 48 && bs[i + 1] <= 57) {
                i += 1
            } else if ((d == 101 || d == 69) && seenDigit) {
                i += 1
                if (i < n && (bs[i] == 43 || bs[i] == 45)) {
                    i += 1
                }
            } else {
                break
            }
        }
        if (seenDigit) {
            return Some(ONum(String.fromUtf8(bs[numStart..i])))
        }
        None
    }
}

/// 对象集合上的 JSONPath 查询，返回全部命中节点。
public func jsonPath(root: Obj, query: String): ArrayList<Obj> {
    let out = ArrayList<Obj>()
    let segs = parsePath(query)
    if (segs.size == 0) {
        out.add(root)
        return out
    }
    var rest = segs
    if (segKindEq(segs[0].kind, PSRoot)) {
        rest = segs[1..segs.size].toArray()
    }
    evalSegs(ArrayList<Obj>([root]), rest, out, root)
    out
}

/// 点分路径便捷访问（等价于逐级 get/at）。
public func objPath(root: Obj, path: String): ?Obj {
    let hits = jsonPath(root, "$." + path)
    if (hits.size == 0) {
        return None
    }
    Some(hits[0])
}

/// 求值段序列。
internal func evalSegs(cur: ArrayList<Obj>, segs: Array<PathSeg>, out: ArrayList<Obj>, root: Obj): Unit {
    if (segs.size == 0) {
        for (c in cur) {
            out.add(c)
        }
        return
    }
    let seg = segs[0]
    let rest = segs[1..segs.size].toArray()
    let next = ArrayList<Obj>()
    for (c in cur) {
        applySeg(c, seg, next, root)
    }
    evalSegs(next, rest, out, root)
}

/// 单段应用到一个节点。
internal func applySeg(node: Obj, seg: PathSeg, out: ArrayList<Obj>, root: Obj): Unit {
    match (seg.kind) {
        case PSRoot => out.add(node)
        case PSChild =>
            if (let Some(v) <- node.get(seg.key)) {
                out.add(v)
            }
        case PSWildcard =>
            for ((_, v) in node.enumerate()) {
                out.add(v)
            }
        case PSUnion =>
            for (it in seg.unionItems) {
                if (it[0]) {
                    // 名称选择：映射成员
                    if (let Some(v) <- node.get(it[1])) {
                        out.add(v)
                    }
                } else {
                    // 下标选择：序列元素
                    if (let Some(v) <- node.at(it[2])) {
                        out.add(v)
                    }
                }
            }
        case PSSlice =>
            let its = node.items()
            let sz = its.size
            var startV = seg.start
            var endV = seg.end
            let stepV = if (seg.step == 0) { 1 } else { seg.step }
            if (stepV > 0) {
                if (startV == Int64.Min) {
                    startV = 0
                }
                if (startV < 0) {
                    startV += sz
                }
                if (endV == Int64.Min) {
                    endV = 0
                }
                if (endV < 0) {
                    endV += sz
                }
                if (endV > sz) { endV = sz }
                if (startV < 0) { startV = 0 }
                var k = startV
                while (k < endV) {
                    if (let Some(v) <- node.at(k)) {
                        out.add(v)
                    }
                    k += stepV
                }
            } else {
                // 负步长：缺省 start 为末尾、end 为首元素之前（Int64.Min 标记）
                if (startV == Int64.Min) {
                    startV = sz - 1
                } else {
                    if (startV < 0) {
                        startV += sz
                    }
                    if (startV >= sz) { startV = sz - 1 }
                    if (startV < 0) { startV = -1 }
                }
                if (endV == Int64.Min) {
                    endV = -1
                } else {
                    if (endV < 0) {
                        endV += sz
                    }
                    if (endV >= sz) { endV = sz - 1 }
                }
                var k = startV
                while (k > endV) {
                    if (let Some(v) <- node.at(k)) {
                        out.add(v)
                    }
                    k += stepV
                }
            }
        case PSRecursive =>
            // 对自身与每个后代应用 inner 段
            let all = ArrayList<Obj>()
            collectAll(node, all)
            if (let Some(inner) <- seg.inner) {
                for (d in all) {
                    applySeg(d, inner, out, root)
                }
            }
        case PSFilter =>
            if (let Some(ast) <- seg.filterAst) {
                for ((_, v) in node.enumerate()) {
                    let r = evalFilter(ast, v, root)
                    if (r) {
                        out.add(v)
                    }
                }
            }
        case _ => ()
    }
}

/// 收集自身与全部后代。
internal func collectAll(node: Obj, out: ArrayList<Obj>): Unit {
    out.add(node)
    for ((_, v) in node.enumerate()) {
        collectAll(v, out)
    }
}

/// 过滤表达式求值（对候选节点 cur）。
internal func evalFilter(node: FNode, cur: Obj, root: Obj): Bool {
    if (let Some(a) <- (node as FAnd)) {
        return evalFilter(a.left, cur, root) && evalFilter(a.right, cur, root)
    }
    if (let Some(o) <- (node as FOr)) {
        return evalFilter(o.left, cur, root) || evalFilter(o.right, cur, root)
    }
    if (let Some(nt) <- (node as FNot)) {
        return !evalFilter(nt.inner, cur, root)
    }
    if (let Some(fb) <- (node as FFuncBool)) {
        return evalFuncBool(fb.call, cur, root)
    }
    if (let Some(ex) <- (node as FExists)) {
        return resolveQuery(ex.path, cur, root).size > 0
    }
    if (let Some(c) <- (node as FCmp)) {
        let l = evalOperand(c.left, cur, root)
        let r = evalOperand(c.right, cur, root)
        return compareOperand(l, r, c.op)
    }
    false
}

/// 解析过滤器中的查询：相对 @ 从 cur 起；绝对 $ 从根起。
internal func resolveQuery(fp: FPath, cur: Obj, root: Obj): ArrayList<Obj> {
    let start = if (fp.fromRoot) { root } else { cur }
    let out = ArrayList<Obj>()
    evalSegs(ArrayList<Obj>([start]), fp.segs, out, root)
    out
}

/// 查询是否为单一查询（仅 child/index 段，RFC 9535 单一查询语义）。
internal func isSingular(fp: FPath): Bool {
    for (s in fp.segs) {
        match (s.kind) {
            case PSChild => ()
            case PSUnion =>
                if (s.unionItems.size != 1) {
                    return false
                }
            case _ => return false
        }
    }
    true
}

/// 操作数求值：None 表示 Nothing（查询未命中或函数求值失败）。
internal func evalOperand(fo: FOperand, cur: Obj, root: Obj): ?Obj {
    if (let Some(p) <- (fo as OPath)) {
        // 非单一查询在比较中按 Nothing 处理（RFC 9535）
        if (!isSingular(p.path)) {
            return None
        }
        let hits = resolveQuery(p.path, cur, root)
        if (hits.size == 0) {
            return None
        }
        return Some(hits[0])
    }
    if (let Some(t) <- (fo as OText)) {
        return Some(ObjText(t.value))
    }
    if (let Some(num) <- (fo as ONum)) {
        return Some(ObjNumber(num.raw))
    }
    if (let Some(b) <- (fo as OBool)) {
        return Some(ObjBool(b.value))
    }
    if (let Some(_) <- (fo as ONullLit)) {
        return Some(ObjNull())
    }
    if (let Some(fn) <- (fo as OFunc)) {
        return evalFuncValue(fn, cur, root)
    }
    None
}

/// 比较操作（RFC 9535 语义：类型不匹配为假；Nothing 只与 Nothing 相等）。
internal func compareOperand(l: ?Obj, r: ?Obj, op: String): Bool {
    if (op == "==") {
        if (let None <- l) {
            if (let None <- r) {
                return true
            }
            return false
        }
        if (let None <- r) {
            return false
        }
        return valueEq(l.getOrThrow(), r.getOrThrow())
    }
    if (op == "!=") {
        return !compareOperand(l, r, "==")
    }
    // 有序比较：双方必须存在
    if (let Some(lv) <- l) {
        if (let Some(rv) <- r) {
            // 数值比较
            if (let Some(ln) <- lv.asFloat()) {
                if (let Some(rn) <- rv.asFloat()) {
                    if (op == "<") { return ln < rn }
                    if (op == "<=") { return ln <= rn }
                    if (op == ">") { return ln > rn }
                    if (op == ">=") { return ln >= rn }
                }
                return false
            }
            // 字符串比较：仅双方均为文本节点（数字的 asText 原文不参与有序比较）
            if (objKindEq(lv.kind, ObjKind.KText) && objKindEq(rv.kind, ObjKind.KText)) {
                if (let Some(lt) <- lv.asText()) {
                    if (let Some(rt) <- rv.asText()) {
                        if (op == "<") { return lt < rt }
                        if (op == "<=") { return lt <= rt }
                        if (op == ">") { return lt > rt }
                        if (op == ">=") { return lt >= rt }
                    }
                }
            }
        }
    }
    false
}

/// 值相等：数值按数值、文本按文本、布尔、null；类型不同为不等。
internal func valueEq(a: Obj, b: Obj): Bool {
    if (objKindEq(a.kind, ObjKind.KNull) && objKindEq(b.kind, ObjKind.KNull)) {
        return true
    }
    if (let Some(an) <- a.asFloat()) {
        if (let Some(bn) <- b.asFloat()) {
            return an == bn
        }
        return false
    }
    if (let Some(ab) <- a.asBool()) {
        if (let Some(bb) <- b.asBool()) {
            return ab == bb
        }
        return false
    }
    if (let Some(at) <- a.asText()) {
        if (let Some(bt) <- b.asText()) {
            return at == bt
        }
    }
    false
}

/// 函数作为布尔（match / search）。
internal func evalFuncBool(fn: OFunc, cur: Obj, root: Obj): Bool {
    if (fn.args.size != 2) {
        return false
    }
    let x = evalOperand(fn.args[0], cur, root)
    let re = evalOperand(fn.args[1], cur, root)
    if (let Some(xv) <- x) {
        if (let Some(txt) <- xv.asText()) {
            if (let Some(rv) <- re) {
                if (let Some(reText) <- rv.asText()) {
                    return regexMatchBool(fn.name, txt, reText)
                }
            }
        }
    }
    false
}

/// 正则匹配：match 全匹配，search 子串搜索。
internal func regexMatchBool(name: String, text: String, pattern: String): Bool {
    try {
        let r = Regex(pattern)
        if (name == "match") {
            return r.matches(text)
        }
        return r.findAll(text).size > 0
    } catch (e: Exception) {
        return false
    }
}

/// 函数求值（返回值形态）。
internal func evalFuncValue(fn: OFunc, cur: Obj, root: Obj): ?Obj {
    if (fn.name == "length") {
        if (fn.args.size != 1) {
            return None
        }
        // 参数必须是单一查询或字符串字面量
        if (let Some(p) <- (fn.args[0] as OPath)) {
            if (!isSingular(p.path)) {
                return None
            }
            let hits = resolveQuery(p.path, cur, root)
            if (hits.size == 0) {
                return None
            }
            let v = hits[0]
            if (let Some(t) <- v.asText()) {
                return Some(ObjNumber("${t.size}"))
            }
            if (objKindEq(v.kind, ObjKind.KSeq)) {
                return Some(ObjNumber("${v.items().size}"))
            }
            if (objKindEq(v.kind, ObjKind.KMap)) {
                return Some(ObjNumber("${v.entries().size}"))
            }
            return None
        }
        if (let Some(t) <- (fn.args[0] as OText)) {
            return Some(ObjNumber("${t.value.size}"))
        }
        return None
    }
    if (fn.name == "count") {
        if (fn.args.size != 1) {
            return None
        }
        // 参数必须是节点列表查询（非单一）
        if (let Some(p) <- (fn.args[0] as OPath)) {
            let hits = resolveQuery(p.path, cur, root)
            return Some(ObjNumber("${hits.size}"))
        }
        return None
    }
    if (fn.name == "value") {
        if (fn.args.size != 1) {
            return None
        }
        if (let Some(p) <- (fn.args[0] as OPath)) {
            if (!isSingular(p.path)) {
                return None
            }
            let hits = resolveQuery(p.path, cur, root)
            if (hits.size == 0) {
                return None
            }
            return Some(hits[0])
        }
        if (let Some(t) <- (fn.args[0] as OText)) {
            return Some(ObjText(t.value))
        }
        return None
    }
    return None
}
