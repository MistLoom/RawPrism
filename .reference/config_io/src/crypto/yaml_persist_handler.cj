package config_io.crypto

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import config_io.{ConfigDiskLoader, ConfigInfo, ConfigRegistry, DynamicValue, DVString, DVArray, DVMap, PersistHandler, Format, effectiveStorageFormat, parseConfigTextByFormat, dynamicValueToJsonValue}

private func ensureJsonPath(root: JsonObject, dotPath: String): JsonObject {
    if (dotPath.isEmpty()) {
        return root
    }
    var current: JsonObject = root
    let segments = dotPath.split(".", removeEmpty: false)
    var si: Int64 = 0
    while (si < segments.size) {
        let seg = segments[si]
        if (seg.isEmpty()) {
            si = si + 1
            continue
        }
        var found: ?JsonValue = None
        for ((k, v) in current.getFields()) {
            if (k == seg) {
                found = Some(v)
                break
            }
        }
        match (found) {
            case Some(v) =>
                match (v.kind()) {
                    case JsObject =>
                        current = v.asObject()
                    case _ =>
                        let newObj = JsonObject()
                        current.put(seg, newObj)
                        current = newObj
                }
            case None =>
                let newObj = JsonObject()
                current.put(seg, newObj)
                current = newObj
        }
        si = si + 1
    }
    current
}

private func readExistingFileAsJsonObject(filePath: String, eff: Format): ?JsonObject {
    let path = Path(filePath)
    if (!exists(path)) {
        return None
    }
    try {
        let bytes = File.readFrom(path)
        let text = String.fromUtf8(bytes)
        let crypto = ConfigCryptoService()
        let decrypted = crypto.decryptConfigText(text, eff)
        let jv = parseConfigTextByFormat(decrypted, eff)
        match (jv.kind()) {
            case JsObject => return Some(jv.asObject())
            case _ => ()
        }
        None
    } catch (_: Exception) {
        None
    }
}

private class YamlCryptoDiskLoader <: ConfigDiskLoader {
    public func loadIntoRegistry(typeName: String, id: String): Unit {
        registryLoadMergedIntoFieldValues(typeName, id)
    }
}

public class YamlCryptoPersistHandler <: PersistHandler {
    public func persist(key: String, info: ConfigInfo, fieldMap: HashMap<String, DynamicValue>): Unit {
        let _ = key
        let basePath = info.basePath
        let eff = effectiveStorageFormat(info.file, info.format)
        let rootObj = match (readExistingFileAsJsonObject(info.file, eff)) {
            case Some(existing) => existing
            case None => JsonObject()
        }
        let targetNode = ensureJsonPath(rootObj, basePath)
        // 扁平格式（TOML/INI/ENV/CONF）使用点分键直接写入，不创建嵌套对象
        let isFlatFormat = match (eff) {
            case Format.TOML => true
            case Format.INI => true
            case Format.ENV => true
            case Format.CONF => true
            case _ => false
        }
        for ((k, v) in fieldMap) {
            if (isFlatFormat) {
                targetNode.put(k, dynamicValueToJsonValue(v))
            } else {
                putNestedField(targetNode, k, dynamicValueToJsonValue(v))
            }
        }
        // 移除已声明但不在 fieldMap 中的字段（支持 removeField 持久化到文件）
        // 仅清理 info.fields 中声明的字段，保留文件中其他自定义键不被误删
        // JsonObject 无 remove 方法，采用重建策略：构建新对象跳过待移除键
        let declaredKeys = ArrayList<String>()
        for (fi in info.fields) {
            if (!declaredKeys.contains(fi.configKey)) {
                declaredKeys.add(fi.configKey)
            }
        }
        let toRemove = ArrayList<String>()
        for (dk in declaredKeys) {
            if (!fieldMap.contains(dk)) {
                toRemove.add(dk)
            }
        }
        var finalRoot = rootObj
        if (toRemove.size > 0) {
            var working: JsonObject
            if (basePath.isEmpty()) {
                working = rootObj
            } else {
                working = targetNode
            }
            for (dk in toRemove) {
                if (isFlatFormat) {
                    working = rebuildSkippingTopKey(working, dk)
                } else {
                    working = rebuildRemovingNestedPath(working, dk)
                }
            }
            if (basePath.isEmpty()) {
                finalRoot = working
            } else {
                putNestedField(rootObj, basePath, working)
                finalRoot = rootObj
            }
        }
        let crypto = ConfigCryptoService()
        let encrypted = crypto.encryptJsonValue(finalRoot)
        let content = crypto.serializeJsonTreeForStorage(encrypted, eff)
        let path = Path(info.file)
        let parentDir = path.parent
        if (!exists(parentDir)) {
            Directory.create(parentDir, recursive: true)
        }
        let outBytes: Array<Byte> = content.toArray()
        File.writeTo(path, outBytes)
    }
}

/// 将扁平点路径键（如 "app.name"）写入为嵌套 JSON 对象结构（{"app":{"name":...}}）。
/// 若中间节点已存在且非对象则覆盖为空对象，保证扁平键到嵌套结构的稳定转换。
private func putNestedField(root: JsonObject, dotKey: String, value: JsonValue): Unit {
    let parts = dotKey.split(".", removeEmpty: false)
    if (parts.size <= 1) {
        root.put(dotKey, value)
        return
    }
    var current = root
    var i: Int64 = 0
    while (i < parts.size - 1) {
        let seg = parts[i]
        if (seg.isEmpty()) {
            i = i + 1
            continue
        }
        var found: ?JsonValue = None
        for ((k, v) in current.getFields()) {
            if (k == seg) {
                found = Some(v)
                break
            }
        }
        match (found) {
            case Some(v) =>
                match (v.kind()) {
                    case JsObject =>
                        current = v.asObject()
                    case _ =>
                        let newObj = JsonObject()
                        current.put(seg, newObj)
                        current = newObj
                }
            case None =>
                let newObj = JsonObject()
                current.put(seg, newObj)
                current = newObj
        }
        i = i + 1
    }
    current.put(parts[parts.size - 1], value)
}

/// 重建 JsonObject，跳过指定顶层键（扁平格式场景）。返回新对象，不修改原对象。
private func rebuildSkippingTopKey(src: JsonObject, skipKey: String): JsonObject {
    let result = JsonObject()
    for ((k, v) in src.getFields()) {
        if (k != skipKey) {
            result.put(k, v)
        }
    }
    result
}

/// 重建 JsonObject，移除点分路径指定的嵌套键（嵌套格式场景）。返回新对象。
/// 如 dotKey="app.server.host" 会从 src.app.server 中移除 host 键。
private func rebuildRemovingNestedPath(src: JsonObject, dotKey: String): JsonObject {
    let parts = dotKey.split(".", removeEmpty: false)
    rebuildRemovingPathRecursive(src, parts, 0)
}

/// 递归重建 JsonObject，在 depth 层移除 parts[depth] 指定的键。
/// 中间路径不存在或非对象时原样保留该子树；仅移除最后一段键，不清理空父对象。
private func rebuildRemovingPathRecursive(src: JsonObject, parts: Array<String>, depth: Int64): JsonObject {
    if (depth >= parts.size) {
        return src
    }
    let targetSeg = parts[depth]
    if (depth == parts.size - 1) {
        let result = JsonObject()
        for ((k, v) in src.getFields()) {
            if (k != targetSeg) {
                result.put(k, v)
            }
        }
        return result
    }
    let result = JsonObject()
    for ((k, v) in src.getFields()) {
        if (k == targetSeg) {
            match (v.kind()) {
                case JsObject =>
                    let rebuilt = rebuildRemovingPathRecursive(v.asObject(), parts, depth + 1)
                    result.put(k, rebuilt)
                case _ =>
                    result.put(k, v)
            }
        } else {
            result.put(k, v)
        }
    }
    result
}

public func installYamlCryptoPersistHandler(): Unit {
    ConfigRegistry.setPersistHandler(YamlCryptoPersistHandler())
    ConfigRegistry.setDiskLoader(YamlCryptoDiskLoader())
    ConfigRegistry.startFileChangeWatcher()
}
