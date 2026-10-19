package config_io

import std.collection.*
import std.convert.Parsable
import stdx.encoding.json.*

public enum Format {
    | AUTO
    | JSON
    | YAML
    | ENV
    | INI
    | TOML
    | XML
    | CONF

    public static func fromExtension(ext: String): Format {
        if (ext == ".json" || ext == ".JSON" || ext == "json" || ext == "JSON") {
            return JSON
        }
        if (ext == ".yaml" || ext == ".YAML" || ext == ".yml" || ext == ".YML" || ext == "yaml" || ext == "yml") {
            return YAML
        }
        if (ext == ".env" || ext == ".ENV" || ext == "env" || ext == "ENV") {
            return ENV
        }
        if (ext == ".ini" || ext == ".INI" || ext == "ini" || ext == "INI") {
            return INI
        }
        if (ext == ".toml" || ext == ".TOML" || ext == "toml" || ext == "TOML") {
            return TOML
        }
        if (ext == ".xml" || ext == ".XML" || ext == "xml" || ext == "XML") {
            return XML
        }
        if (ext == ".conf" || ext == ".CONF" || ext == "conf" || ext == "CONF") {
            return CONF
        }
        AUTO
    }
}

public interface DynamicValue {
    func toString(): String
    func toInt(): ?Int64
    func toFloat(): ?Float64
    func toBool(): ?Bool
    func toArray(): ?Array<DynamicValue>
    func toMap(): ?HashMap<String, DynamicValue>
    func toJsonString(): ?String
}

public class DVInt <: DynamicValue {
    public let value: Int64

    public init(value: Int64) {
        this.value = value
    }

    public func toString(): String {
        value.toString()
    }

    public func toInt(): ?Int64 {
        Some(value)
    }

    public func toFloat(): ?Float64 {
        Some(Float64(value))
    }

    public func toBool(): ?Bool {
        None
    }

    public func toArray(): ?Array<DynamicValue> {
        None
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        None
    }

    public func toJsonString(): ?String {
        None
    }
}

public class DVFloat <: DynamicValue {
    public let value: Float64

    public init(value: Float64) {
        this.value = value
    }

    public func toString(): String {
        value.toString()
    }

    public func toInt(): ?Int64 {
        Some(Int64(value))
    }

    public func toFloat(): ?Float64 {
        Some(value)
    }

    public func toBool(): ?Bool {
        None
    }

    public func toArray(): ?Array<DynamicValue> {
        None
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        None
    }

    public func toJsonString(): ?String {
        None
    }
}

public class DVString <: DynamicValue {
    public let value: String

    public init(value: String) {
        this.value = value
    }

    public func toString(): String {
        value
    }

    public func toInt(): ?Int64 {
        try { Some(Int64.parse(value)) } catch (_) { None }
    }

    public func toFloat(): ?Float64 {
        try { Some(Float64.parse(value)) } catch (_) { None }
    }

    public func toBool(): ?Bool {
        if (value == "true" || value == "1") {
            Some(true)
        } else if (value == "false" || value == "0") {
            Some(false)
        } else {
            None
        }
    }

    public func toArray(): ?Array<DynamicValue> {
        None
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        None
    }

    public func toJsonString(): ?String {
        Some(value)
    }
}

public class DVBool <: DynamicValue {
    public let value: Bool

    public init(value: Bool) {
        this.value = value
    }

    public func toString(): String {
        value.toString()
    }

    public func toInt(): ?Int64 {
        Some(if (value) { 1 } else { 0 })
    }

    public func toFloat(): ?Float64 {
        Some(if (value) { 1.0 } else { 0.0 })
    }

    public func toBool(): ?Bool {
        Some(value)
    }

    public func toArray(): ?Array<DynamicValue> {
        None
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        None
    }

    public func toJsonString(): ?String {
        None
    }
}

public class DVArray <: DynamicValue {
    public let value: Array<DynamicValue>

    public init(value: Array<DynamicValue>) {
        this.value = value
    }

    public func toString(): String {
        var result = "["
        for (i in 0..value.size) {
            if (i > 0) {
                result = result + ", "
            }
            result = result + value[i].toString()
        }
        result + "]"
    }

    public func toInt(): ?Int64 {
        None
    }

    public func toFloat(): ?Float64 {
        None
    }

    public func toBool(): ?Bool {
        None
    }

    public func toArray(): ?Array<DynamicValue> {
        Some(value)
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        None
    }

    public func toJsonString(): ?String {
        None
    }
}

public class DVMap <: DynamicValue {
    public let value: HashMap<String, DynamicValue>

    public init(value: HashMap<String, DynamicValue>) {
        this.value = value
    }

    public func toString(): String {
        var result = "{"
        var first = true
        for ((k, v) in value) {
            if (!first) {
                result = result + ", "
            }
            first = false
            result = result + "\"" + k + "\": " + v.toString()
        }
        result + "}"
    }

    public func toInt(): ?Int64 {
        None
    }

    public func toFloat(): ?Float64 {
        None
    }

    public func toBool(): ?Bool {
        None
    }

    public func toArray(): ?Array<DynamicValue> {
        None
    }

    public func toMap(): ?HashMap<String, DynamicValue> {
        Some(value)
    }

    public func toJsonString(): ?String {
        None
    }
}

/// 运行时判断类型名是否为基础类型（与宏侧 isBasicType 逻辑对齐）
/// 供 config.crypto 包的 registryLoadMergedIntoFieldValues 调用
public func isBasicFieldTypeName(typeName: String): Bool {
    let basicTypes = ["String", "Int64", "Int32", "Int16", "Bool",
                      "Float64", "Float32", "UInt8", "UInt16", "UInt32", "UInt64"]
    for (bt in basicTypes) {
        if (typeName == bt) {
            return true
        }
    }
    false
}

/// 将 DynamicValue 转换为 JsonValue
/// DVString 先尝试解析为 JSON（兼容 nestedArrayToDV 产生的 JSON 字符串），失败则作为纯字符串
/// DVArray→JsonArray, DVMap→JsonObject, DVInt→JsonInt, DVBool→JsonBool, DVFloat→JsonFloat
public func dynamicValueToJsonValue(v: DynamicValue): JsonValue {
    if (v is DVString) {
        let s = v.toString()
        try {
            let jv = JsonValue.fromStr(s)
            match (jv.kind()) {
                case JsObject => return jv
                case JsArray => return jv
                case _ => ()
            }
        } catch (_: Exception) {
            ()
        }
        return JsonString(s)
    }
    if (v is DVInt) {
        match (v.toInt()) {
            case Some(i) => return JsonInt(i)
            case None => ()
        }
    }
    if (v is DVFloat) {
        match (v.toFloat()) {
            case Some(f) => return JsonFloat(f)
            case None => ()
        }
    }
    if (v is DVBool) {
        match (v.toBool()) {
            case Some(b) => return JsonBool(b)
            case None => ()
        }
    }
    if (v is DVArray) {
        match (v.toArray()) {
            case Some(arr) =>
                let items = ArrayList<JsonValue>()
                for (item in arr) {
                    items.add(dynamicValueToJsonValue(item))
                }
                return JsonArray(items.toArray())
            case None => ()
        }
    }
    if (v is DVMap) {
        match (v.toMap()) {
            case Some(m) =>
                let obj = JsonObject()
                for ((k, val) in m) {
                    obj.put(k, dynamicValueToJsonValue(val))
                }
                return obj
            case None => ()
        }
    }
    JsonString(v.toString())
}

/// 字段级：成员与配置键别名、路径、默认值、惰性、敏感、校验正则、加密算法与密钥引用；自动保存/同步仅在 ConfigInfo 套级。
public struct FieldInfo {
    /// 类/结构体中的成员名（源码标识；合并多条宏时按此键合并）
    public let memberName: String
    /// 序列化时实际读取/写入的键名（别名）
    public let configKey: String
    /// 点分路径（嵌套配置）
    public let path: String
    public let fieldTypeName: String
    public let defaultValue: ?DynamicValue
    public let isLazy: Bool
    /// 为 true 时参与敏感封装（与 ConfigCryptoService 规则可并用）
    public let sensitive: Bool
    /// 非空时对写入值做正则校验（整段匹配语义由表达式本身决定，常用 ^...$）
    public let verifyPattern: String
    /// 加密元数据：空为默认；sym:enc:v1 为当前对称封装；asym:rsa 等预留
    public let cryptoAlgorithm: String
    /// 非默认密钥时的逻辑引用（与 KeyManager 扩展对接）
    public let cryptoKeyId: String
    /// 环境变量名：设置后该字段优先从指定环境变量读取值
    public let env: String

    public init(
        memberName: String,
        configKey: String,
        path: String,
        fieldTypeName: String,
        defaultValue: ?DynamicValue,
        isLazy: Bool,
        sensitive: Bool,
        verifyPattern: String,
        cryptoAlgorithm: String,
        cryptoKeyId: String,
        env: String
    ) {
        this.memberName = memberName
        this.configKey = configKey
        this.path = path
        this.fieldTypeName = fieldTypeName
        this.defaultValue = defaultValue
        this.isLazy = isLazy
        this.sensitive = sensitive
        this.verifyPattern = verifyPattern
        this.cryptoAlgorithm = cryptoAlgorithm
        this.cryptoKeyId = cryptoKeyId
        this.env = env
    }
}

public struct ConfigSource {
    public let format: Format
    public let file: String
    public let prefix: String
    public let priority: Int64
    /// 为 true 时表示 firstExists 模式：加载时只使用第一个存在的文件，不再尝试后续文件
    public let firstExists: Bool

    public init(format: Format, file: String, prefix: String, priority: Int64) {
        this.format = format
        this.file = file
        this.prefix = prefix
        this.priority = priority
        this.firstExists = false
    }

    public init(format: Format, file: String, prefix: String, priority: Int64, firstExists: Bool) {
        this.format = format
        this.file = file
        this.prefix = prefix
        this.priority = priority
        this.firstExists = firstExists
    }
}

public struct ConfigInfo {
    public let configType: String
    public let file: String
    public let format: Format
    public let sources: Array<ConfigSource>
    public let fields: Array<FieldInfo>
    public let basePath: String
    /// 为真时字段变更后写主文件（与 autosync 合并生效见 ConfigRegistry）
    public let autosave: Bool
    /// 为真时启用与外部文件同步策略；为真时亦视为需要在 set 后持久化（与 autosave 二选一即可）
    public let autosync: Bool
    public let validate: Bool
    public let stream: Bool

    public init(
        configType: String,
        file: String,
        format: Format,
        sources: Array<ConfigSource>,
        fields: Array<FieldInfo>,
        basePath: String,
        autosave: Bool,
        autosync: Bool,
        validate: Bool,
        stream: Bool
    ) {
        this.configType = configType
        this.file = file
        this.format = format
        this.sources = sources
        this.fields = fields
        this.basePath = basePath
        this.autosave = autosave
        this.autosync = autosync
        this.validate = validate
        this.stream = stream
    }
}

public struct ConfigMeta {
    public let id: String
    public let file: String
    public let format: Format
    public let listenerCount: Int64
    public let changeCount: Int64

    public init(id: String, file: String, format: Format, listenerCount: Int64, changeCount: Int64) {
        this.id = id
        this.file = file
        this.format = format
        this.listenerCount = listenerCount
        this.changeCount = changeCount
    }
}

public class ConfigException <: Exception {
    public let code: String
    public let context: HashMap<String, String>

    public init(message: String) {
        super(message)
        this.code = "CONFIG_ERROR"
        this.context = HashMap<String, String>()
    }

    public init(code: String, message: String) {
        super(message)
        this.code = code
        this.context = HashMap<String, String>()
    }

    public init(code: String, message: String, context: HashMap<String, String>) {
        super(message)
        this.code = code
        this.context = context
    }

    public func withContext(key: String, value: String): ConfigException {
        this.context.add(key, value)
        this
    }
}

public class ConfigRef<T> {
    private let ref: T
    private let typeName: String
    private let id: String

    public init(instance: T) {
        this.ref = instance
        this.typeName = ""
        this.id = "default"
    }

    public init(instance: T, typeName: String, id: String) {
        this.ref = instance
        this.typeName = typeName
        this.id = id
    }

    public func get(): T {
        ref
    }

    public func set(field: String, value: String): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Int64): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Int32): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Int16): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Bool): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Float64): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Float32): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Array<String>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Array<Int64>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Array<Bool>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: Array<Float64>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: HashMap<String, String>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: HashMap<String, Int64>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: HashMap<String, Bool>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: HashMap<String, Float64>): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }

    public func set(field: String, value: DynamicValue): Unit {
        if (typeName.size > 0) {
            Config.set(typeName, id, field, value)
        }
    }
}

public struct GlobalDefaults {
    public var autosave: Bool
    public var autosync: Bool
    public var validate: Bool
    public var watchInterval: Int64

    public init() {
        this.autosave = false
        this.autosync = true
        this.validate = false
        this.watchInterval = 1000
    }
}

public class ConfigDefaults {
    private static var __defaults__: GlobalDefaults = GlobalDefaults()

    public static func getDefaults(): GlobalDefaults {
        __defaults__
    }

    public static func setAutosave(enabled: Bool): Unit {
        __defaults__.autosave = enabled
    }

    public static func setAutosync(enabled: Bool): Unit {
        __defaults__.autosync = enabled
    }

    public static func setValidate(enabled: Bool): Unit {
        __defaults__.validate = enabled
    }

    public static func setWatchInterval(ms: Int64): Unit {
        __defaults__.watchInterval = ms
    }

    public static func reset(): Unit {
        __defaults__ = GlobalDefaults()
    }
}

/// 从路径取最后一个点后缀（含点），无点则返回空串
public func fileSuffixFromPath(path: String): String {
    var lastDot: Int64 = -1
    var i: Int64 = 0
    while (i < path.size) {
        if (path[i] == '.'.toArray()[0]) {
            lastDot = i
        }
        i = i + 1
    }
    if (lastDot < 0) {
        return ""
    }
    path[lastDot..path.size]
}

/// 声明为 AUTO 时按路径扩展名推断存储格式；无法推断时默认 YAML（与历史行为一致）
public func effectiveStorageFormat(filePath: String, declared: Format): Format {
    match (declared) {
        case AUTO => ()
        case _ => return declared
    }
    let suf = fileSuffixFromPath(filePath)
    let inferred = Format.fromExtension(suf)
    match (inferred) {
        case AUTO => Format.YAML
        case _ => inferred
    }
}

/// 嵌套配置接口：支持 fromJson/defaultValue/toJson 双向转换，供 Config.getArray/getMap 泛型约束使用
public interface ConfigNested<T> {
    static func fromJson(jv: JsonValue): T
    static func defaultValue(): T
    func toJson(): JsonValue
}

/// 旧版泛型监听器接口（主项目 AppConfigListener 使用）；新代码推荐用 BaseConfigListener
public interface ConfigListener<T> {
    func onLoaded(instanceRef: ConfigRef<T>): Unit
    func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit
    func onReloaded(): Unit
    func onSaved(): Unit
    func onError(error: ConfigException): Unit
    func onValidationError(field: String, message: String): Unit
}