package config_io

import std.collection.*
import std.convert.Parsable
import stdx.encoding.json.*
import yaml4cj.yaml.{decode, encode}

/// 多格式配置与 JsonValue 互转（敏感字段加解密与注册表扁平键一致）；YAML/JSON 经 yaml4cj 与 stdx.json

// --- YAML：ENC 标量行内引号（与 ConfigCryptoService 对齐，避免 crypto 与 config 循环依赖）---

private func quoteEncPrefixInLine(line: String, encPrefix: String): String {
    match (line.indexOf(encPrefix)) {
        case None => return line
        case Some(encIdx) =>
            if (encIdx >= 1) {
                let prev = line[encIdx - 1]
                if (prev == '"'.toArray()[0]) {
                    return line
                }
            }
            let prefix = line[0..encIdx]
            let value = line[encIdx..line.size]
            let escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
            return prefix + "\"" + escaped + "\""
    }
}

private func quoteEncScalarLineIfNeeded(line: String): String {
    var l = quoteEncPrefixInLine(line, "ENC:v1:")
    l = quoteEncPrefixInLine(l, "ENC:AES256:")
    l
}

public func normalizeYamlEncScalarsInText(yaml: String): String {
    var text = yaml.replace("\r\n", "\n")
    text = text.replace("\r", "\n")
    let lines = text.split("\n", removeEmpty: false)
    let out = ArrayList<String>()
    for (line in lines) {
        out.add(quoteEncScalarLineIfNeeded(line))
    }
    var joined = ""
    var i: Int64 = 0
    while (i < out.size) {
        if (i > 0) {
            joined = joined + "\n"
        }
        joined = joined + out[i]
        i = i + 1
    }
    joined
}

private func looksLikeJsonContent(content: String): Bool {
    let t = content.trimAscii()
    if (t.size < 1) {
        return false
    }
    let b0 = t[0]
    b0 == '{'.toArray()[0] || b0 == '['.toArray()[0]
}

public func parseConfigTextByFormat(text: String, fmt: Format): JsonValue {
    let trimmed = text.trimAscii()
    match (fmt) {
        case JSON => JsonValue.fromStr(trimmed)
        case YAML =>
            let normalized = normalizeYamlEncScalarsInText(trimmed)
            try {
                decode(normalized.toArray())
            } catch (_: Exception) {
                if (looksLikeJsonContent(trimmed)) {
                    JsonValue.fromStr(trimmed)
                } else {
                    throw Exception("YAML 解析失败")
                }
            }
        case ENV => parseEnvToJson(trimmed)
        case INI | CONF => parseIniLikeToJson(trimmed, true)
        case TOML => parseTomlSubsetToJson(trimmed)
        case XML => parseXmlFlatEntriesToJson(trimmed)
        case AUTO => throw Exception("parseConfigTextByFormat: 须先 effectiveStorageFormat")
    }
}

public func serializeJsonValueByFormat(root: JsonValue, fmt: Format): String {
    match (fmt) {
        case JSON => root.toString()
        case YAML =>
            let yamlBytes = encode(root)
            normalizeYamlEncScalarsInText(String.fromUtf8(yamlBytes))
        case ENV => serializeJsonToEnv(root)
        case INI | CONF => serializeJsonToIniLike(root, true)
        case TOML => serializeJsonToTomlSubset(root)
        case XML => serializeJsonToXmlEntries(root)
        case AUTO => throw Exception("serializeJsonValueByFormat: 须先 effectiveStorageFormat")
    }
}

/// 将嵌套对象展平为点分键，供 ConfigRegistry 顶层键快照（与 YAML 扁平顶层键语义一致）
public func flattenJsonObjectForRegistry(root: JsonValue): JsonObject {
    match (root.kind()) {
        case JsObject => ()
        case _ => throw Exception("配置根须为 JSON 对象")
    }
    flattenRecursive(root.asObject(), "")
}

private func flattenRecursive(obj: JsonObject, prefix: String): JsonObject {
    let out = JsonObject()
    for ((k, v) in obj.getFields()) {
        let p = if (prefix.size > 0) {
            prefix + "." + k
        } else {
            k
        }
        match (v.kind()) {
            case JsObject =>
                let inner = flattenRecursive(v.asObject(), p)
                for ((ik, iv) in inner.getFields()) {
                    out.put(ik, iv)
                }
            case _ =>
                out.put(p, v)
        }
    }
    out
}

// --- ENV ---

private func parseEnvToJson(text: String): JsonValue {
    let root = JsonObject()
    let lines = text.split("\n", removeEmpty: false)
    for (line in lines) {
        var ln = line.trimAscii()
        if (ln.size == 0) {
            continue
        }
        if (ln[0] == '#'.toArray()[0]) {
            continue
        }
        if (ln.startsWith("export ")) {
            ln = ln[7..ln.size].trimAscii()
        }
        match (ln.indexOf("=")) {
            case None => continue
            case Some(eq) =>
                let key = ln[0..eq].trimAscii()
                var rest = ln[eq + 1..ln.size]
                if (rest.size >= 2 && rest[0] == '"'.toArray()[0] && rest[rest.size - 1] == '"'.toArray()[0]) {
                    rest = rest[1..rest.size - 1].replace("\\\"", "\"").replace("\\\\", "\\")
                }
                if (key.size > 0) {
                    root.put(key, stringToJsonLeaf(rest))
                }
        }
    }
    root
}

private func stringToJsonLeaf(raw: String): JsonValue {
    let t = raw.trimAscii()
    if (t == "true") {
        return JsonBool(true)
    }
    if (t == "false") {
        return JsonBool(false)
    }
    try {
        return JsonInt(Int64.parse(t))
    } catch (_: Exception) {
        ()
    }
    try {
        return JsonFloat(Float64.parse(t))
    } catch (_: Exception) {
        ()
    }
    JsonString(t)
}

private func indexOfFrom(hay: String, needle: String, from: Int64): ?Int64 {
    if (from < 0 || from >= hay.size) {
        return None
    }
    let sub = hay[from..hay.size]
    match (sub.indexOf(needle)) {
        case None => None
        case Some(i) => Some(from + i)
    }
}

private func xmlEscapeText(s: String): String {
    s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

private func xmlUnescapeText(s: String): String {
    s.replace("&quot;", "\"").replace("&gt;", ">").replace("&lt;", "<").replace("&amp;", "&")
}

/// INI/CONF：行首 # 与 ; 为注释；[节]；key=value；值可带引号
private func parseIniLikeToJson(text: String, semicolonComment: Bool): JsonValue {
    var currentSection = ""
    let root = JsonObject()
    let lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n", removeEmpty: false)
    for (line in lines) {
        var ln = line.trimAscii()
        if (ln.size == 0) {
            continue
        }
        if (ln[0] == '#'.toArray()[0]) {
            continue
        }
        if (semicolonComment && ln[0] == ';'.toArray()[0]) {
            continue
        }
        if (ln.size >= 2 && ln[0] == '['.toArray()[0] && ln[ln.size - 1] == ']'.toArray()[0]) {
            currentSection = ln[1..ln.size - 1].trimAscii()
            continue
        }
        match (ln.indexOf("=")) {
            case None => continue
            case Some(eq) =>
                let rawKey = ln[0..eq].trimAscii()
                if (rawKey.size == 0) {
                    continue
                }
                var rest = ln[eq + 1..ln.size].trimAscii()
                rest = stripIniQuotedValue(rest)
                let fullKey = if (currentSection.size > 0) {
                    currentSection + "." + rawKey
                } else {
                    rawKey
                }
                root.put(fullKey, stringToJsonLeaf(rest))
        }
    }
    root
}

private func stripIniQuotedValue(s: String): String {
    if (s.size >= 2 && s[0] == '"'.toArray()[0] && s[s.size - 1] == '"'.toArray()[0]) {
        return s[1..s.size - 1].replace("\\\"", "\"").replace("\\\\", "\\")
    }
    if (s.size >= 2 && s[0] == '\''.toArray()[0] && s[s.size - 1] == '\''.toArray()[0]) {
        return s[1..s.size - 1]
    }
    s
}

/// TOML 子集：行首 # 注释；[表]；key = value
private func parseTomlSubsetToJson(text: String): JsonValue {
    parseIniLikeToJson(text, false)
}

/// 简易 XML 节点（替代 std.xml.XmlElement，支持嵌套解析）
private class XmlNode {
    public var name: String
    public var content: String
    public var attributes: HashMap<String, String>
    public var children: ArrayList<XmlNode>

    public init(name: String) {
        this.name = name
        this.content = ""
        this.attributes = HashMap<String, String>()
        this.children = ArrayList<XmlNode>()
    }

    public func getAttr(key: String): ?String {
        attributes.get(key)
    }
}

/// 跳过空白字符，返回第一个非空白位置
private func skipWhitespace(text: String, pos: Int64): Int64 {
    var p = pos
    while (p < text.size) {
        let c = text[p]
        if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) {
            break
        }
        p += 1
    }
    p
}

/// 递归解析 XML 文本为 XmlNode 树
/// 支持：<tag attr="val">content<child/></tag>, <tag/>, <!-- comment -->, <?xml ...?>
private func parseXmlToNode(text: String, pos: Int64): (XmlNode, Int64) {
    // pos 指向 '<'
    var p = pos + 1  // 跳过 '<'
    // 读取标签名
    var nameEnd = p
    while (nameEnd < text.size) {
        let c = text[nameEnd]
        if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == '>'.toArray()[0] || c == '/'.toArray()[0]) {
            break
        }
        nameEnd += 1
    }
    let tagName = text[p..nameEnd]
    let node = XmlNode(tagName)
    p = nameEnd

    // 解析属性
    p = skipWhitespace(text, p)
    while (p < text.size && text[p] != '>'.toArray()[0] && text[p] != '/'.toArray()[0]) {
        // 读取属性名
        var attrNameEnd = p
        while (attrNameEnd < text.size && text[attrNameEnd] != '='.toArray()[0] && text[attrNameEnd] != 0x20) {
            attrNameEnd += 1
        }
        if (attrNameEnd >= text.size || text[attrNameEnd] != '='.toArray()[0]) {
            break
        }
        let attrName = text[p..attrNameEnd]
        p = attrNameEnd + 1  // 跳过 '='
        // 跳过引号
        if (p < text.size && (text[p] == '"'.toArray()[0] || text[p] == '\''.toArray()[0])) {
            let quoteChar = text[p]
            p += 1
            var attrValEnd = p
            while (attrValEnd < text.size && text[attrValEnd] != quoteChar) {
                attrValEnd += 1
            }
            let attrVal = text[p..attrValEnd]
            node.attributes.add(attrName, xmlUnescapeText(attrVal))
            p = attrValEnd + 1  // 跳过结束引号
        }
        p = skipWhitespace(text, p)
    }

    // 检查自闭合标签 <tag/>
    if (p < text.size && text[p] == '/'.toArray()[0]) {
        p += 1  // 跳过 '/'
        if (p < text.size && text[p] == '>'.toArray()[0]) {
            p += 1  // 跳过 '>'
        }
        return (node, p)
    }

    // 跳过 '>'
    if (p < text.size && text[p] == '>'.toArray()[0]) {
        p += 1
    }

    // 解析内容和子元素
    var contentBuf = StringBuilder()
    while (p < text.size) {
        if (text[p] == '<'.toArray()[0]) {
            // 检查是否是结束标签 </tag>
            if (p + 1 < text.size && text[p + 1] == '/'.toArray()[0]) {
                // 结束标签
                p += 2  // 跳过 '</'
                var closeEnd = p
                while (closeEnd < text.size && text[closeEnd] != '>'.toArray()[0]) {
                    closeEnd += 1
                }
                p = closeEnd + 1  // 跳过 '>'
                // 保存累积的文本内容
                node.content = contentBuf.toString().trimAscii()
                return (node, p)
            }
            // 检查是否是注释 <!--
            if (p + 3 < text.size && text[p + 1] == '!'.toArray()[0] && text[p + 2] == '-'.toArray()[0] && text[p + 3] == '-'.toArray()[0]) {
                // 跳过注释
                p += 4
                while (p + 2 < text.size) {
                    if (text[p] == '-'.toArray()[0] && text[p + 1] == '-'.toArray()[0] && text[p + 2] == '>'.toArray()[0]) {
                        p += 3
                        break
                    }
                    p += 1
                }
                continue
            }
            // 检查是否是处理指令 <?
            if (p + 1 < text.size && text[p + 1] == '?'.toArray()[0]) {
                p += 2
                while (p + 1 < text.size) {
                    if (text[p] == '?'.toArray()[0] && text[p + 1] == '>'.toArray()[0]) {
                        p += 2
                        break
                    }
                    p += 1
                }
                continue
            }
            // 递归解析子元素
            let (child, newP) = parseXmlToNode(text, p)
            node.children.add(child)
            p = newP
        } else {
            contentBuf.append(Rune(text[p]))
            p += 1
        }
    }
    node.content = contentBuf.toString().trimAscii()
    (node, p)
}

/// 从 XmlNode 的属性列表中获取 "key" 属性值
/// 用于向后兼容 <entry key="..."> 格式
private func getXmlNodeKey(node: XmlNode): ?String {
    node.getAttr("key")
}

/// 递归将 XmlNode 转换为 JsonValue
/// - 叶子节点（无子节点）：从 text content 提取标量值
/// - 容器节点（有子节点）：构建 JsonObject，子元素按 key 分组
///   - 有 key 属性：用属性值作 JSON 键（向后兼容 <entry key="...">）
///   - 无 key 属性：用元素标签名作 JSON 键
///   - 同名/同 key 的多个子元素自动合并为 JsonArray
private func xmlNodeToJsonValue(node: XmlNode): JsonValue {
    if (node.children.size == 0) {
        return stringToJsonLeaf(xmlUnescapeText(node.content.trimAscii()))
    }
    let keyToValues = HashMap<String, ArrayList<JsonValue>>()
    let keyOrder = ArrayList<String>()
    for (child in node.children) {
        let key = match (getXmlNodeKey(child)) {
            case Some(k) => k
            case None => child.name
        }
        let childVal = xmlNodeToJsonValue(child)
        match (keyToValues.get(key)) {
            case Some(lst) =>
                lst.add(childVal)
            case None =>
                let lst = ArrayList<JsonValue>()
                lst.add(childVal)
                keyToValues.add(key, lst)
                keyOrder.add(key)
        }
    }
    let obj = JsonObject()
    for (key in keyOrder) {
        match (keyToValues.get(key)) {
            case Some(lst) =>
                if (lst.size == 1) {
                    obj.put(key, lst[0])
                } else {
                    obj.put(key, JsonArray(lst.toArray()))
                }
            case None => ()
        }
    }
    obj
}

/// XML 解析：自定义递归解析器，支持嵌套 XML 元素
/// 向后兼容 <entry key="...">value</entry> 格式
/// 支持嵌套 <config><app><name>x</name></app></config> 格式
private func parseXmlFlatEntriesToJson(text: String): JsonValue {
    let trimmed = text.trimAscii()
    // 找到第一个 '<' 开始解析
    var pos = skipWhitespace(trimmed, 0)
    // 跳过 XML 声明 <?xml ...?>
    if (pos + 1 < trimmed.size && trimmed[pos] == '<'.toArray()[0] && trimmed[pos + 1] == '?'.toArray()[0]) {
        pos += 2
        while (pos + 1 < trimmed.size) {
            if (trimmed[pos] == '?'.toArray()[0] && trimmed[pos + 1] == '>'.toArray()[0]) {
                pos += 2
                break
            }
            pos += 1
        }
        pos = skipWhitespace(trimmed, pos)
    }
    if (pos >= trimmed.size || trimmed[pos] != '<'.toArray()[0]) {
        return JsonObject()
    }
    let (root, _) = parseXmlToNode(trimmed, pos)
    // root 是根元素，其子元素是配置项
    if (root.children.size == 0) {
        return JsonObject()
    }
    let keyToValues = HashMap<String, ArrayList<JsonValue>>()
    let keyOrder = ArrayList<String>()
    for (child in root.children) {
        let key = match (getXmlNodeKey(child)) {
            case Some(k) => k
            case None => child.name
        }
        let childVal = xmlNodeToJsonValue(child)
        match (keyToValues.get(key)) {
            case Some(lst) =>
                lst.add(childVal)
            case None =>
                let lst = ArrayList<JsonValue>()
                lst.add(childVal)
                keyToValues.add(key, lst)
                keyOrder.add(key)
        }
    }
    let obj = JsonObject()
    for (key in keyOrder) {
        match (keyToValues.get(key)) {
            case Some(lst) =>
                if (lst.size == 1) {
                    obj.put(key, lst[0])
                } else {
                    obj.put(key, JsonArray(lst.toArray()))
                }
            case None => ()
        }
    }
    obj
}

private func jsonValueToStorageScalar(v: JsonValue): String {
    match (v.kind()) {
        case JsString => v.asString().getValue()
        case JsInt => v.asInt().getValue().toString()
        case JsFloat => v.asFloat().getValue().toString()
        case JsBool => if (v.asBool().getValue()) {
            "true"
        } else {
            "false"
        }
        case _ => v.toString()
    }
}

private func envValueNeedsQuotes(s: String): Bool {
    var i: Int64 = 0
    while (i < s.size) {
        let c = s[i]
        if (c == ' '.toArray()[0] || c == '\n'.toArray()[0] || c == '\t'.toArray()[0] || c == '#'.toArray()[0] || c == '='.toArray()[0]) {
            return true
        }
        i = i + 1
    }
    false
}

private func escapeEnvScalar(s: String): String {
    if (!envValueNeedsQuotes(s)) {
        return s
    }
    let esc = s.replace("\\", "\\\\").replace("\"", "\\\"")
    "\"" + esc + "\""
}

private func serializeJsonToEnv(root: JsonValue): String {
    match (root.kind()) {
        case JsObject => ()
        case _ => throw Exception("ENV 序列化根须为 JSON 对象")
    }
    let obj = root.asObject()
    let lines = ArrayList<String>()
    for ((k, v) in obj.getFields()) {
        lines.add(k + "=" + escapeEnvScalar(jsonValueToStorageScalar(v)))
    }
    var out = ""
    var i: Int64 = 0
    while (i < lines.size) {
        if (i > 0) {
            out = out + "\n"
        }
        out = out + lines[i]
        i = i + 1
    }
    out
}

private func serializeJsonToIniLike(root: JsonValue, semicolonComment: Bool): String {
    let _ = semicolonComment
    match (root.kind()) {
        case JsObject => ()
        case _ => throw Exception("INI/CONF 序列化根须为 JSON 对象")
    }
    let obj = root.asObject()
    let lines = ArrayList<String>()
    for ((k, v) in obj.getFields()) {
        let val = jsonValueToStorageScalar(v)
        let line = if (val.contains("\n") || val.contains("\"")) {
            k + "=\"" + val.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        } else {
            k + "=" + val
        }
        lines.add(line)
    }
    var out = ""
    var j: Int64 = 0
    while (j < lines.size) {
        if (j > 0) {
            out = out + "\n"
        }
        out = out + lines[j]
        j = j + 1
    }
    out
}

private func serializeJsonToTomlSubset(root: JsonValue): String {
    match (root.kind()) {
        case JsObject => ()
        case _ => throw Exception("TOML 序列化根须为 JSON 对象")
    }
    let obj = root.asObject()
    let lines = ArrayList<String>()
    for ((k, v) in obj.getFields()) {
        let val = jsonValueToStorageScalar(v)
        let needsQuote = envValueNeedsQuotes(val) || val.size == 0
        let rendered = if (needsQuote) {
            "\"" + val.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        } else {
            val
        }
        lines.add(k + " = " + rendered)
    }
    var out = ""
    var j: Int64 = 0
    while (j < lines.size) {
        if (j > 0) {
            out = out + "\n"
        }
        out = out + lines[j]
        j = j + 1
    }
    out
}

private func serializeJsonToXmlEntries(root: JsonValue): String {
    match (root.kind()) {
        case JsObject => ()
        case _ => throw Exception("XML 序列化根须为 JSON 对象")
    }
    let obj = root.asObject()
    var body = ""
    var i: Int64 = 0
    for ((k, v) in obj.getFields()) {
        if (i > 0) {
            body = body + "\n"
        }
        body = body + serializeJsonValueToXmlNode(k, v, 1)
        i = i + 1
    }
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<configuration>\n" + body + "\n</configuration>"
}

/// 递归将 JSON 键值对序列化为 XML 元素
/// - 标量值：`<entry key="k">value</entry>`（向后兼容）
/// - 对象值：`<k><child>...</child>...</k>`（嵌套元素）
/// - 数组值：多个同名元素
private func serializeJsonValueToXmlNode(key: String, v: JsonValue, indent: Int64): String {
    var pad = ""
    for (_ in 0..indent) {
        pad = pad + "  "
    }
    match (v.kind()) {
        case JsObject =>
            let inner = v.asObject()
            var innerBody = ""
            var j: Int64 = 0
            for ((ik, iv) in inner.getFields()) {
                if (j > 0) {
                    innerBody = innerBody + "\n"
                }
                innerBody = innerBody + serializeJsonValueToXmlNode(ik, iv, indent + 1)
                j = j + 1
            }
            pad + "<" + xmlEscapeText(key) + ">\n" + innerBody + "\n" + pad + "</" + xmlEscapeText(key) + ">"
        case JsArray =>
            let arr = v.asArray()
            var parts = ArrayList<String>()
            for (elem in arr.getItems()) {
                parts.add(serializeJsonValueToXmlNode(key, elem, indent))
            }
            var result = ""
            var first = true
            for (p in parts) {
                if (!first) {
                    result = result + "\n"
                }
                result = result + p
                first = false
            }
            result
        case _ =>
            let val = xmlEscapeText(jsonValueToStorageScalar(v))
            pad + "<entry key=\"" + xmlEscapeText(key) + "\">" + val + "</entry>"
    }
}
