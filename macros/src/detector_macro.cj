// RawPrism 检测器属性宏（第 16 节：宏在独立的宏包中定义）。
//
// 用法（9.4）：
//   @Detector[typeId = "entity.ticket", within = ["text.*"]]
//   public class TicketId <: Getter<String> {
//       public func detect(scope: Span, ctx: DetectContext): Unit { ... }
//       public func materialize(region: Region, ctx: MaterializeContext): String { ... }
//   }
//
// 宏为被标注的类生成 Detector 接口要求的四个属性：
//   typeId / within / dependsOn / authoritative
// 属性：typeId（必填字符串）、within / dependsOn / authoritative（可选，字符串数组，
// dependsOn 与 authoritative 的元素按 TypeId 解释）。
macro package rawprism_macros

import std.ast.*
import std.collection.*

/// @Detector 属性宏：为类注入 Detector 接口的四个属性。
public macro Detector(attrTokens: Tokens, input: Tokens): Tokens {
    expandDetector(attrTokens, input)
}

/// 无属性形式：typeId 为空串时由调用方自行使用（等价于全缺省）。
public macro Detector(input: Tokens): Tokens {
    expandDetector(Tokens(), input)
}

/// 解析后的 Detector 宏属性。
internal class DetectorAttrs {
    public var typeId: String = ""
    public var within: ArrayList<String> = ArrayList<String>()
    public var dependsOn: ArrayList<String> = ArrayList<String>()
    public var authoritative: ArrayList<String> = ArrayList<String>()

    public init() {}
}

internal func expandDetector(attrTokens: Tokens, input: Tokens): Tokens {
    let attrs = parseDetectorAttrs(attrTokens)
    if (attrs.typeId.isEmpty()) {
        throw Exception("@Detector：必须提供 typeId 属性，例如 @Detector[typeId = \"entity.ticket\"]")
    }

    // 字符串字面量 Token（value 不含引号，由字面量 Token 语义承载）
    let typeIdLit = Token(TokenKind.STRING_LITERAL, attrs.typeId)
    let withinTok = stringArrayTokens(attrs.within)
    let dependsTok = typeIdArrayTokens(attrs.dependsOn)
    let authTok = typeIdArrayTokens(attrs.authoritative)

    let gen = quote(
        public prop typeId: TypeId {
            get() { TypeId($typeIdLit) }
        }
        public prop within: Array<String> {
            get() { $withinTok }
        }
        public prop dependsOn: Array<TypeId> {
            get() { $dependsTok }
        }
        public prop authoritative: Array<TypeId> {
            get() { $authTok }
        }
    )

    // 注入到类体最后一个 '}' 之前
    var lastRcurl: Int64 = -1
    var i: Int64 = 0
    while (i < input.size) {
        if (input[i].kind == TokenKind.RCURL) {
            lastRcurl = i
        }
        i += 1
    }
    if (lastRcurl < 0) {
        throw Exception("@Detector：被标注的目标必须是类声明")
    }
    let head = input[0..lastRcurl]
    let tail = input[lastRcurl..input.size]
    let nl = Token(TokenKind.NL)
    head + nl + gen + nl + tail
}

/// 解析宏属性：key = "v" 与 key = ["v1", "v2"] 两种形态。
internal func parseDetectorAttrs(attrTokens: Tokens): DetectorAttrs {
    let out = DetectorAttrs()
    var i: Int64 = 0
    let n = attrTokens.size
    while (i < n) {
        let t = attrTokens[i]
        if (t.kind == TokenKind.IDENTIFIER) {
            let key = t.value
            // 向后找 '='
            var j = i + 1
            while (j < n && attrTokens[j].kind != TokenKind.ASSIGN && attrTokens[j].kind != TokenKind.IDENTIFIER) {
                j += 1
            }
            if (j < n && attrTokens[j].kind == TokenKind.ASSIGN) {
                j += 1
                if (j < n) {
                    let v = attrTokens[j]
                    if (v.kind == TokenKind.STRING_LITERAL) {
                        setAttr(out, key, stripLiteralQuotes(v.value))
                        i = j + 1
                        continue
                    }
                    if (v.kind == TokenKind.LSQUARE) {
                        // 数组：收集到匹配的 ']'
                        let items = ArrayList<String>()
                        var k = j + 1
                        while (k < n && attrTokens[k].kind != TokenKind.RSQUARE) {
                            if (attrTokens[k].kind == TokenKind.STRING_LITERAL) {
                                items.add(stripLiteralQuotes(attrTokens[k].value))
                            }
                            k += 1
                        }
                        if (key == "within") {
                            out.within = items
                        } else if (key == "dependsOn") {
                            out.dependsOn = items
                        } else if (key == "authoritative") {
                            out.authoritative = items
                        }
                        i = k + 1
                        continue
                    }
                }
            }
        }
        i += 1
    }
    out
}

internal func setAttr(out: DetectorAttrs, key: String, value: String): Unit {
    if (key == "typeId") {
        out.typeId = value
    } else if (key == "within") {
        out.within.add(value)
    } else if (key == "dependsOn") {
        out.dependsOn.add(value)
    } else if (key == "authoritative") {
        out.authoritative.add(value)
    }
}

/// STRING_LITERAL Token 的 value 可能带引号：统一剥掉。
internal func stripLiteralQuotes(s: String): String {
    if (s.size >= 2) {
        let bs = s.toArray()
        if (bs[0] == 34 && bs[bs.size - 1] == 34) {
            return String.fromUtf8(bs[1..bs.size - 1])
        }
        if (bs[0] == 39 && bs[bs.size - 1] == 39) {
            return String.fromUtf8(bs[1..bs.size - 1])
        }
    }
    s
}

/// 构建 Array<String> 字面量 Tokens：["a", "b"]（Tokens 支持 + 拼接）。
internal func stringArrayTokens(items: ArrayList<String>): Tokens {
    var ts: Tokens = Tokens()
    ts = ts + Token(TokenKind.LSQUARE)
    var i: Int64 = 0
    while (i < items.size) {
        if (i > 0) {
            ts = ts + Token(TokenKind.COMMA)
        }
        ts = ts + Token(TokenKind.STRING_LITERAL, items[i])
        i += 1
    }
    ts = ts + Token(TokenKind.RSQUARE)
    ts
}

/// 构建 Array<TypeId> 字面量 Tokens：[TypeId("a"), TypeId("b")]。
internal func typeIdArrayTokens(items: ArrayList<String>): Tokens {
    var ts: Tokens = Tokens()
    ts = ts + Token(TokenKind.LSQUARE)
    var i: Int64 = 0
    while (i < items.size) {
        if (i > 0) {
            ts = ts + Token(TokenKind.COMMA)
        }
        ts = ts + Token(TokenKind.IDENTIFIER, "TypeId")
        ts = ts + Token(TokenKind.LPAREN)
        ts = ts + Token(TokenKind.STRING_LITERAL, items[i])
        ts = ts + Token(TokenKind.RPAREN)
        i += 1
    }
    ts = ts + Token(TokenKind.RSQUARE)
    ts
}
