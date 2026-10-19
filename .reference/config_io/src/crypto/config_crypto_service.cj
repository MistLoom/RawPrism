package config_io.crypto

import std.collection.*
import config_io.*
import stdx.encoding.json.*

/// 配置文件敏感字段自动封装/解封（脱敏落盘）；树形正文统一经 JsonValue 处理，再按存储格式序列化（JSON/YAML/ENV/INI/TOML/XML/CONF 经 format_codec；AUTO 由路径推断）。
/// 敏感键名仅来自 SensitiveFieldRegistry（\@encrypt/mergeFieldInfos 等显式登记），无内置默认键名或关键词启发式。
public class ConfigCryptoService {
    private let sealer: SecretSealer
    private let prefixV1: String = "ENC:v1:"
    private let legacyPrefix: String = "ENC:AES256:"

    public init() {
        let key = KeyManager.loadKey()
        this.sealer = SecretSealer(key)
    }

    /// 是否为敏感键：仅当名称已在 SensitiveFieldRegistry 中显式登记（实例方法便于与加解密路径一致调用）
    public func isSensitiveField(fieldName: String): Bool {
        SensitiveFieldRegistry.isRegistered(fieldName)
    }

    public func isEncryptedValue(value: String): Bool {
        value.startsWith(prefixV1) || value.startsWith(legacyPrefix)
    }

    private func isEnvPlaceholder(value: String): Bool {
        let t = value.trimAscii()
        t.size >= 3 && t[0] == '$'.toArray()[0] && t[1] == '{'.toArray()[0] && t[t.size - 1] == '}'.toArray()[0]
    }

    public func encryptValue(value: String): String {
        let t = value.trimAscii()
        if (t.isEmpty() || isEnvPlaceholder(t)) {
            return value
        }
        // 已封装或首尾空白导致误判时，按 trim 后判断，避免对密文二次封装
        if (t.startsWith(prefixV1)) {
            return t
        }
        let sealed = sealer.sealString(t)
        try {
            let _ = sealer.openString(sealed)
        } catch (e: Exception) {
            throw Exception("封装结果解密验证失败: ${e.message}")
        }
        sealed
    }

    public func decryptValue(stored: String): String {
        if (stored.startsWith(prefixV1)) {
            try {
                return sealer.openString(stored)
            } catch (e: Exception) {
                println("[ConfigCryptoService] 解封失败: ${e.message}")
                throw Exception("配置字段解密失败")
            }
        }
        if (stored.startsWith(legacyPrefix)) {
            println("[ConfigCryptoService] 检测到旧版 ENC:AES256: 前缀，无法解封，请重新保存配置")
            return stored
        }
        stored
    }

    /// 加密树按存储格式写出（与 parseConfigTextByFormat 对称）
    public func serializeJsonTreeForStorage(root: JsonValue, storageFmt: Format): String {
        serializeJsonValueByFormat(root, storageFmt)
    }

    public func decryptConfigText(content: String, storageFmt: Format): String {
        let trimmed = content.trimAscii()
        if (trimmed.isEmpty()) {
            return content
        }
        try {
            let jsonValue = parseConfigTextByFormat(trimmed, storageFmt)
            let decrypted = decryptJsonValue(jsonValue)
            return serializeJsonTreeForStorage(decrypted, storageFmt)
        } catch (e: Exception) {
            println("[ConfigCryptoService] 配置解密失败: ${e.message}")
            return content
        }
    }

    public func encryptConfigText(content: String, storageFmt: Format): String {
        let trimmed = content.trimAscii()
        if (trimmed.isEmpty()) {
            return content
        }
        let jsonValue = parseConfigTextByFormat(trimmed, storageFmt)
        let encrypted = encryptJsonValue(jsonValue)
        try {
            let out = serializeJsonTreeForStorage(encrypted, storageFmt)
            try {
                let jv2 = parseConfigTextByFormat(out.trimAscii(), storageFmt)
                let _ = decryptJsonValue(jv2)
            } catch (e: Exception) {
                println("[ConfigCryptoService] 加密结果自检未通过（已忽略，仍落盘）: ${e.message}")
            }
            return out
        } catch (e: Exception) {
            throw Exception("配置加密失败: ${e.message}")
        }
    }

    private func decryptJsonValue(value: JsonValue): JsonValue {
        match (value.kind()) {
            case JsObject => return decryptJsonObject(value.asObject())
            case JsArray => return decryptJsonArray(value.asArray())
            case _ => value
        }
    }

    private func decryptJsonObject(obj: JsonObject): JsonValue {
        let newObj = JsonObject()
        for ((key, val) in obj.getFields()) {
            if (isSensitiveField(key)) {
                if (val is JsonString) {
                    newObj.put(key, JsonString(decryptValue(val.asString().getValue())))
                } else {
                    match (val.kind()) {
                        case JsArray =>
                            // 敏感键且值为字符串数组：逐项解封（如 httpApi.keyAuth.allowedKeys）
                            newObj.put(key, decryptJsonArraySensitiveStringElements(val.asArray()))
                        case _ =>
                            newObj.put(key, decryptJsonValue(val))
                    }
                }
            } else {
                newObj.put(key, decryptJsonValue(val))
            }
        }
        newObj
    }

    /// 敏感键下的数组：字符串元素按 ENC 解封，其余递归
    private func decryptJsonArraySensitiveStringElements(arr: JsonArray): JsonValue {
        let newArr = ArrayList<JsonValue>()
        for (item in arr.getItems()) {
            if (item is JsonString) {
                newArr.add(JsonString(decryptValue(item.asString().getValue())))
            } else {
                newArr.add(decryptJsonValue(item))
            }
        }
        JsonArray(newArr.toArray())
    }

    private func decryptJsonArray(arr: JsonArray): JsonValue {
        let newArr = ArrayList<JsonValue>()
        for (item in arr.getItems()) {
            newArr.add(decryptJsonValue(item))
        }
        JsonArray(newArr.toArray())
    }

    public func encryptJsonValue(value: JsonValue): JsonValue {
        match (value.kind()) {
            case JsObject => return encryptJsonObject(value.asObject())
            case JsArray => return encryptJsonArray(value.asArray())
            case _ => value
        }
    }

    private func encryptJsonObject(obj: JsonObject): JsonValue {
        let newObj = JsonObject()
        for ((key, val) in obj.getFields()) {
            if (isSensitiveField(key)) {
                if (val is JsonString) {
                    newObj.put(key, JsonString(encryptValue(val.asString().getValue())))
                } else {
                    match (val.kind()) {
                        case JsArray =>
                            // 敏感键且值为字符串数组：逐项封装（如 httpApi.keyAuth.allowedKeys）
                            newObj.put(key, encryptJsonArraySensitiveStringElements(val.asArray()))
                        case _ =>
                            newObj.put(key, encryptJsonValue(val))
                    }
                }
            } else {
                newObj.put(key, encryptJsonValue(val))
            }
        }
        newObj
    }

    /// 敏感键下的数组：字符串元素逐项封装，嵌套对象/数组仍递归
    private func encryptJsonArraySensitiveStringElements(arr: JsonArray): JsonValue {
        let newArr = ArrayList<JsonValue>()
        for (item in arr.getItems()) {
            if (item is JsonString) {
                newArr.add(JsonString(encryptValue(item.asString().getValue())))
            } else {
                newArr.add(encryptJsonValue(item))
            }
        }
        JsonArray(newArr.toArray())
    }

    private func encryptJsonArray(arr: JsonArray): JsonValue {
        let newArr = ArrayList<JsonValue>()
        for (item in arr.getItems()) {
            newArr.add(encryptJsonValue(item))
        }
        JsonArray(newArr.toArray())
    }
}
