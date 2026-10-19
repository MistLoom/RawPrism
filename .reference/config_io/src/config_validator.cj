package config_io

import std.regex.Regex

public class ConfigValidator {
    private let store: ConfigStore
    private let listenerManager: ListenerManager

    public init(store: ConfigStore, listenerManager: ListenerManager) {
        this.store = store
        this.listenerManager = listenerManager
    }

    public func validateField(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        let info = store.getConfigInfo(typeName, id)
        match (findFieldInfo(info, field)) {
            case Some(fi) =>
                if (fi.verifyPattern.size > 0) {
                    let text = value.toString()
                    try {
                        let re = Regex(fi.verifyPattern)
                        if (re.find(text).isNone()) {
                            let msg = "校验未通过，正则: ${fi.verifyPattern}"
                            listenerManager.dispatchValidationError(typeName, id, field, msg)
                            throw ConfigException("VALIDATION_ERROR", msg)
                        }
                    } catch (e: ConfigException) {
                        throw e
                    } catch (e: Exception) {
                        let msg = "校验失败: ${e.message}"
                        listenerManager.dispatchValidationError(typeName, id, field, msg)
                        throw ConfigException("VALIDATION_ERROR", msg)
                    }
                }
            case None => ()
        }
    }

    private func findFieldInfo(info: ConfigInfo, field: String): ?FieldInfo {
        for (f in info.fields) {
            if (f.configKey == field || f.memberName == field) {
                return Some(f)
            }
        }
        None
    }
}
