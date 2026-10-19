package config_io.crypto

import std.fs.*
import std.env.getVariable
import std.collection.*
import stdx.encoding.json.*
import config_io.ConfigRegistry
import config_io.readConfigFileText
import config_io.{ConfigInfo, DVArray, DVBool, DVFloat, DVInt, DVMap, DVString, DynamicValue, Format,
               effectiveStorageFormat, flattenJsonObjectForRegistry, isBasicFieldTypeName, parseConfigTextByFormat}

private func jsonToDynamicValue(v: JsonValue): DynamicValue {
    match (v.kind()) {
        case JsString => DVString(v.asString().getValue())
        case JsInt => DVInt(v.asInt().getValue())
        case JsFloat => DVFloat(v.asFloat().getValue())
        case JsBool => DVBool(v.asBool().getValue())
        case JsObject =>
            let map = HashMap<String, DynamicValue>()
            for ((k, vv) in v.asObject().getFields()) {
                map.add(k, jsonToDynamicValue(vv))
            }
            DVMap(map)
        case JsArray =>
            let arr = ArrayList<DynamicValue>()
            for (item in v.asArray().getItems()) {
                arr.add(jsonToDynamicValue(item))
            }
            DVArray(arr.toArray())
        case _ => DVString(v.toString())
    }
}

private func stripBasePathPrefix(key: String, basePath: String): ?String {
    if (basePath.isEmpty()) {
        return Some(key)
    }
    let prefix = basePath + "."
    if (key.startsWith(prefix)) {
        Some(key[prefix.size..key.size])
    } else {
        None
    }
}

/// 按点路径导航 JSON 树，返回路径终点的 JsonValue
/// 例如 navigateToJsonValue(root, "app.features") 依次取 root["app"]["features"]
private func navigateToJsonValue(root: JsonValue, dotPath: String): ?JsonValue {
    if (dotPath.isEmpty()) {
        return Some(root)
    }
    var current: JsonValue = root
    let parts = dotPath.split(".", removeEmpty: false)
    for (seg in parts) {
        if (seg.size == 0) {
            continue
        }
        match (current.kind()) {
            case JsObject =>
                let obj = current.asObject()
                var found: ?JsonValue = None
                for ((k, v) in obj.getFields()) {
                    if (k == seg) {
                        found = Some(v)
                        break
                    }
                }
                match (found) {
                    case Some(v) => current = v
                    case None => return None
                }
            case _ =>
                return None
        }
    }
    Some(current)
}

/// 单层：路径 + 生效格式 + 键前缀 + 优先级（数值越大越后合并、覆盖能力越强）
private struct LoadLayer {
    public let file: String
    public let eff: Format
    public let prefix: String
    public let priority: Int64
    public let stream: Bool
    public let firstExists: Bool

    public init(file: String, eff: Format, prefix: String, priority: Int64, stream: Bool, firstExists: Bool) {
        this.file = file
        this.eff = eff
        this.prefix = prefix
        this.priority = priority
        this.stream = stream
        this.firstExists = firstExists
    }
}

private func sortLayersAsc(layers: ArrayList<LoadLayer>): Array<LoadLayer> {
    let n = layers.size
    if (n <= 1) {
        return layers.toArray()
    }
    var arr = layers.toArray()
    var i: Int64 = 0
    while (i < n) {
        var j: Int64 = i + 1
        while (j < n) {
            if (arr[j].priority < arr[i].priority) {
                let t = arr[i]
                arr[i] = arr[j]
                arr[j] = t
            }
            j = j + 1
        }
        i = i + 1
    }
    arr
}

private func buildLayers(info: ConfigInfo): Array<LoadLayer> {
    let list = ArrayList<LoadLayer>()
    let mainEff = effectiveStorageFormat(info.file, info.format)
    list.add(LoadLayer(info.file, mainEff, "", 0, info.stream, false))
    for (s in info.sources) {
        let eff = effectiveStorageFormat(s.file, s.format)
        list.add(LoadLayer(s.file, eff, s.prefix, s.priority, info.stream, s.firstExists))
    }
    sortLayersAsc(list)
}

private func applyPrefixToFlatKey(prefix: String, flatKey: String): String {
    if (prefix.isEmpty()) {
        flatKey
    } else {
        prefix + "." + flatKey
    }
}

/// 从磁盘合并主文件与 sources（按 priority 升序叠加，后者覆盖前者）；若某层设 firstExists，则找到第一个存在文件后即停止。
/// 字段值以扁平点路径键（如 "app.name"）存入注册表，使 getField("app.name") 可直接命中。
/// 文件缺失或结构损坏时输出日志并跳过，由调用方使用结构体字段默认值兜底。
public func registryLoadMergedIntoFieldValues(typeName: String, id: String): Unit {
    let info: ConfigInfo
    try {
        info = ConfigRegistry.getConfigInfo(typeName, id)
    } catch (_: Exception) {
        return
    }
    let basePath = info.basePath
    let merged = HashMap<String, DynamicValue>()
    let crypto = ConfigCryptoService()

    let layers = buildLayers(info)
    var loadedFirstExists = false
    var anyFileLoaded = false
    for (layer in layers) {
        if (loadedFirstExists) {
            break
        }
        let p = Path(layer.file)
        if (!exists(p)) {
            println("[ConfigLoader] 配置文件不存在: ${layer.file}，将使用默认值")
            continue
        }
        var text: String
        try {
            text = readConfigFileText(p, layer.stream)
        } catch (e: Exception) {
            println("[ConfigLoader] 读取配置文件失败: ${layer.file} - ${e.message}，将使用默认值")
            continue
        }
        text = crypto.decryptConfigText(text, layer.eff)
        try {
            let jv = parseConfigTextByFormat(text, layer.eff)

            // 保留原始 JSON 树供嵌套字段读取
            let origTree: ?JsonValue = match (jv.kind()) {
                case JsObject => Some(jv)
                case _ => None
            }

            // 构建嵌套字段 configKey 集合（非基础类型字段）
            let nestedKeys = HashSet<String>()
            for (fi in info.fields) {
                if (!isBasicFieldTypeName(fi.fieldTypeName)) {
                    nestedKeys.add(fi.configKey)
                }
            }

            // 1. 展平处理基础类型字段（跳过属于嵌套字段的键）
            let flat = flattenJsonObjectForRegistry(jv)
            for ((k, val) in flat.getFields()) {
                let withPref = applyPrefixToFlatKey(layer.prefix, k)
                match (stripBasePathPrefix(withPref, basePath)) {
                    case Some(stripped) =>
                        // 检查是否属于嵌套字段（键本身或键的前缀匹配嵌套字段名）
                        var belongsToNested = false
                        if (nestedKeys.contains(stripped)) {
                            belongsToNested = true
                        } else {
                            for (nk in nestedKeys) {
                                if (stripped.startsWith(nk + ".")) {
                                    belongsToNested = true
                                    break
                                }
                            }
                        }
                        if (!belongsToNested) {
                            merged[stripped] = jsonToDynamicValue(val)
                        }
                    case None => ()
                }
            }

            // 2. 嵌套字段从非展平 JSON 树直接读取
            for (fi in info.fields) {
                if (!isBasicFieldTypeName(fi.fieldTypeName)) {
                    let filePath = if (basePath.size > 0) {
                        basePath + "." + fi.configKey
                    } else {
                        fi.configKey
                    }
                    match (origTree) {
                        case Some(tree) =>
                            match (navigateToJsonValue(tree, filePath)) {
                                case Some(val) =>
                                    let withPref = applyPrefixToFlatKey(layer.prefix, fi.configKey)
                                    match (stripBasePathPrefix(withPref, basePath)) {
                                        case Some(stripped) =>
                                            merged[stripped] = jsonToDynamicValue(val)
                                        case None => ()
                                    }
                                case None => ()
                            }
                        case None => ()
                    }
                }
            }

            anyFileLoaded = true
            if (layer.firstExists) {
                loadedFirstExists = true
            }
        } catch (e: Exception) {
            println("[ConfigLoader] 解析配置文件失败（结构错误）: ${layer.file} - ${e.message}，该文件将被跳过并使用默认值")
        }
    }
    // 环境变量覆盖：@key[env="VAR"] 标注的字段从环境变量取值，优先级高于所有文件层
    for (fi in info.fields) {
        if (fi.env.size > 0) {
            match (getVariable(fi.env)) {
                case Some(envVal) =>
                    merged[fi.configKey] = DVString(envVal)
                    println("[ConfigLoader] 字段 ${fi.configKey} 已从环境变量 ${fi.env} 覆盖为 ${envVal}")
                case None => ()
            }
        }
    }
    if (anyFileLoaded) {
        println("[ConfigLoader] 配置 ${typeName}:${id} 加载完成，共 ${merged.size} 个字段")
    } else {
        println("[ConfigLoader] 配置 ${typeName}:${id} 无可用文件，全部使用结构体默认值")
    }
    ConfigRegistry.resetFieldValuesFromTopLevelMap(typeName, id, merged)
}

/// 与历史名称一致：等价于合并加载
public func registryLoadMainFileIntoFieldValues(typeName: String, id: String): Unit {
    registryLoadMergedIntoFieldValues(typeName, id)
}

/// 读取环境变量（供宏生成代码调用，避免消费方手动 import std.env）
public func readEnvVar(name: String): ?String {
    getVariable(name)
}

/// 环境变量源模式：跳过文件加载，直接从环境变量读取字段并合并到注册表
/// 逐字段合并：仅覆盖已设置的环境变量，未设置的字段保留原有值
public func registryLoadFromEnv(typeName: String, id: String): Unit {
    let info: ConfigInfo
    try {
        info = ConfigRegistry.getConfigInfo(typeName, id)
    } catch (_: Exception) {
        return
    }
    var count: Int64 = 0
    for (fi in info.fields) {
        if (fi.env.size > 0) {
            match (getVariable(fi.env)) {
                case Some(envVal) =>
                    try {
                        ConfigRegistry.setSilent(typeName, id, fi.configKey, DVString(envVal))
                        count = count + 1
                        println("[ConfigLoader] 字段 ${fi.configKey} 从环境变量 ${fi.env} 读取")
                    } catch (_: Exception) {
                        println("[ConfigLoader] 字段 ${fi.configKey} 环境变量值校验失败，跳过")
                    }
                case None => ()
            }
        }
    }
    println("[ConfigLoader] 配置 ${typeName}:${id} 环境变量加载完成，共 ${count} 个字段")
}
