package config_io

import std.collection.*
import std.sync.*
import std.fs.*

public class ConfigStore {
    private let lock: Mutex = Mutex()
    private let configs: HashMap<String, ConfigInfo> = HashMap()
    private let instanceMap: HashMap<String, Any> = HashMap()
    private let fieldValues: HashMap<String, HashMap<String, DynamicValue>> = HashMap()
    private let configCache: HashMap<String, Any> = HashMap()
    private let cacheEnabled: AtomicBool = AtomicBool(true)

    public func register(typeName: String, info: ConfigInfo, id: String): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            if (configs.contains(key)) {
                throw ConfigException("REGISTRATION_ERROR", "配置 ${key} 已注册")
            }
            configs.add(key, info)
            fieldValues.add(key, HashMap<String, DynamicValue>())
        }
    }

    public func getConfigInfo(typeName: String, id: String): ConfigInfo {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (configs.get(key)) {
                case Some(info) => info
                case None => throw ConfigException("NOT_FOUND", "配置 ${key} 未注册")
            }
        }
    }

    public func updateConfigInfo(typeName: String, id: String, info: ConfigInfo): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            configs.remove(key)
            configs.add(key, info)
            if (cacheEnabled.load()) {
                configCache.remove(key)
            }
        }
    }

    public func getInstance(typeName: String, id: String): Any {
        let key = "${typeName}:${id}"
        if (cacheEnabled.load()) {
            synchronized(lock) {
                match (configCache.get(key)) {
                    case Some(cached) => return cached
                    case None => ()
                }
            }
        }
        synchronized(lock) {
            match (instanceMap.get(key)) {
                case Some(inst) => 
                    if (cacheEnabled.load()) {
                        configCache.remove(key)
                        configCache.add(key, inst)
                    }
                    inst
                case None => throw ConfigException("NOT_FOUND", "配置 ${key} 未注册，请先使用 @config 宏注册")
            }
        }
    }

    public func addInstance(typeName: String, id: String, instance: Any): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            instanceMap.remove(key)
            instanceMap.add(key, instance)
            if (cacheEnabled.load()) {
                configCache.remove(key)
                configCache.add(key, instance)
            }
        }
    }

    public func getInstanceOpt(typeName: String, id: String): ?Any {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            instanceMap.get(key)
        }
    }

    public func getFieldValue(typeName: String, id: String, field: String): ?DynamicValue {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (fieldValues.get(key)) {
                case Some(values) => values.get(field)
                case None => None
            }
        }
    }

    public func hasAnyFieldValue(typeName: String, id: String): Bool {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (fieldValues.get(key)) {
                case Some(values) => values.size > 0
                case None => false
            }
        }
    }

    public func setFieldValue(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (fieldValues.get(key)) {
                case Some(values) => values.add(field, value)
                case None => ()
            }
        }
    }

    public func getFieldValuesSnapshot(typeName: String, id: String): HashMap<String, DynamicValue> {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (fieldValues.get(key)) {
                case Some(m) => m
                case None => HashMap<String, DynamicValue>()
            }
        }
    }

    public func resetFieldValuesFromTopLevelMap(typeName: String, id: String, m: HashMap<String, DynamicValue>): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            let fresh = HashMap<String, DynamicValue>()
            for ((k, v) in m) {
                fresh.add(k, v)
            }
            fieldValues.remove(key)
            fieldValues.add(key, fresh)
            if (cacheEnabled.load()) {
                configCache.remove(key)
            }
        }
    }

    public func removeFieldValue(typeName: String, id: String, field: String): Bool {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (fieldValues.get(key)) {
                case Some(values) =>
                    let existed = values.contains(field)
                    if (existed) {
                        values.remove(field)
                        if (cacheEnabled.load()) {
                            configCache.remove(key)
                        }
                    }
                    existed
                case None => false
            }
        }
    }

    public func instances(typeName: String): Array<(String, Any)> {
        let results = ArrayList<(String, Any)>()
        let prefix = "${typeName}:"
        synchronized(lock) {
            for ((key, instance) in instanceMap) {
                if (key.startsWith(prefix)) {
                    results.add((extractId(key), instance))
                }
            }
        }
        results.toArray()
    }

    public func mainFileExists(typeName: String, id: String): Bool {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (configs.get(key)) {
                case Some(info) => exists(Path(info.file))
                case None => throw ConfigException("NOT_FOUND", "配置 ${key} 未注册")
            }
        }
    }

    public func getAutosyncConfigs(): Array<(String, ConfigInfo)> {
        let results = ArrayList<(String, ConfigInfo)>()
        synchronized(lock) {
            for ((k, info) in configs) {
                if (info.autosync) {
                    results.add((k, info))
                }
            }
        }
        results.toArray()
    }

    private func extractId(key: String): String {
        match (key.indexOf(":")) {
            case Some(idx) => key[idx + 1..key.size]
            case None => "default"
        }
    }
}
