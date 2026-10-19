package config_io

import std.collection.*
import std.sync.*
import std.fs.*
import std.convert.Parsable
import std.regex.Regex
import stdx.encoding.json.*

public interface ConfigDiskLoader {
    func loadIntoRegistry(typeName: String, id: String): Unit
}

public interface BaseConfigListener {
    func onLoaded(instanceRef: ConfigRef<Any>): Unit
    func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit
    func onReloaded(): Unit
    func onSaved(): Unit
    func onError(error: ConfigException): Unit
    func onValidationError(field: String, message: String): Unit
    func getId(): String
}

public interface PersistHandler {
    func persist(key: String, info: ConfigInfo, fieldMap: HashMap<String, DynamicValue>): Unit
}

public class ConfigMap {
    private let typeName: String
    private let id: String
    private let path: String

    public init(typeName: String) {
        this.typeName = typeName
        this.id = "default"
        this.path = ""
    }

    public init(typeName: String, id: String) {
        this.typeName = typeName
        this.id = id
        this.path = ""
    }

    private init(typeName: String, id: String, path: String) {
        this.typeName = typeName
        this.id = id
        this.path = path
    }

    private func fullPath(key: String): String {
        if (path.isEmpty()) {
            key
        } else {
            path + "." + key
        }
    }

    public func get(key: String): ?DynamicValue {
        ConfigRegistry.getField(typeName, id, fullPath(key))
    }

    public operator func [](key: String): ConfigMap {
        ConfigMap(typeName, id, fullPath(key))
    }

    public func set(key: String, value: DynamicValue): Unit {
        ConfigRegistry.set(typeName, id, fullPath(key), value)
    }

    public func set(key: String, value: String): Unit {
        set(key, DVString(value))
    }

    public func set(key: String, value: Int64): Unit {
        set(key, DVInt(value))
    }

    public func set(key: String, value: Bool): Unit {
        set(key, DVBool(value))
    }

    public func set(key: String, value: Float64): Unit {
        set(key, DVFloat(value))
    }

    public func set(value: DynamicValue): Unit {
        if (!path.isEmpty()) {
            ConfigRegistry.set(typeName, id, path, value)
        }
    }

    public func set(value: String): Unit {
        set(DVString(value))
    }

    public func set(value: Int64): Unit {
        set(DVInt(value))
    }

    public func set(value: Bool): Unit {
        set(DVBool(value))
    }

    public func set(value: Float64): Unit {
        set(DVFloat(value))
    }

    public func toDynamicValue(): ?DynamicValue {
        if (path.isEmpty()) {
            ConfigRegistry.getField(typeName, id, "")
        } else {
            ConfigRegistry.getField(typeName, id, path)
        }
    }
}

public class ConfigRegistry {
    private static let lock: Mutex = Mutex()
    private static let store: ConfigStore = ConfigStore()
    private static let listenerManager: ListenerManager = ListenerManager(store)
    private static let validator: ConfigValidator = ConfigValidator(store, listenerManager)
    private static let persister: ConfigPersister = ConfigPersister(store)
    private static let fileWatcher: ConfigFileWatcher = ConfigFileWatcher(store, listenerManager)
    private static let merger: ConfigMerger = ConfigMerger(store)
    private static var diskLoader: ?ConfigDiskLoader = None

    public static func register(typeName: String, info: ConfigInfo, id: String): Unit {
        store.register(typeName, info, id)
        if (info.autosync) {
            println("ConfigRegistry: autosync 已启用，配置文件: ${info.file}")
        }
    }

    public static func get(typeName: String, id: String): Any {
        store.getInstance(typeName, id)
    }

    public static func getRef(typeName: String, id: String): ConfigRef<Any> {
        let instance = get(typeName, id)
        ConfigRef<Any>(instance)
    }

    public static func on(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener {
        listenerManager.addListener(typeName, id, listener)
    }

    public static func off(typeName: String, id: String, listener: BaseConfigListener): Unit {
        listenerManager.removeListener(typeName, id, listener)
    }

    public static func instances(typeName: String): Array<(String, Any)> {
        store.instances(typeName)
    }

    public static func info(typeName: String, id: String): ConfigMeta {
        let result: ConfigMeta
        synchronized(lock) {
            let info = store.getConfigInfo(typeName, id)
            let listenerCount = listenerManager.getListenerCount(typeName, id)
            result = ConfigMeta(
                id,
                info.file,
                info.format,
                listenerCount,
                0
            )
        }
        result
    }

    public static func save(typeName: String, id: String): Unit {
        persister.persistSync(typeName, id)
        listenerManager.dispatchSaved(typeName, id)
    }

    public static func reload(typeName: String, id: String): Unit {
        let key = "${typeName}:${id}"
        let loaderOpt: ?ConfigDiskLoader
        synchronized(lock) {
            loaderOpt = diskLoader
        }
        match (loaderOpt) {
            case Some(loader) =>
                loader.loadIntoRegistry(typeName, id)
            case None =>
                let info = store.getConfigInfo(typeName, id)
                loadFromFile(key, info)
        }
        listenerManager.dispatchReloaded(typeName, id)
    }

    public static func set(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        let info = store.getConfigInfo(typeName, id)
        let actualFormat = effectiveStorageFormat(info.file, info.format)
        let isIniOrConf = match (actualFormat) {
            case Format.INI | Format.CONF => true
            case _ => false
        }
        if (isIniOrConf) {
            let hasNested = match (value) {
                case _: DVMap => true
                case _: DVArray => true
                case _ => false
            }
            if (hasNested) {
                listenerManager.dispatchError(
                    typeName,
                    id,
                    ConfigException("INVALID_NESTED", "INI/CONF 格式不支持嵌套结构，字段 ${field} 的嵌套值已跳过，建议使用 JSON 或 YAML 格式")
                )
                return
            }
        }
        validator.validateField(typeName, id, field, value)
        let oldValue = store.getFieldValue(typeName, id, field)
        store.setFieldValue(typeName, id, field, value)
        listenerManager.dispatchChanged(typeName, id, field, oldValue, Some(value))

        let updatedInfo = store.getConfigInfo(typeName, id)
        if (updatedInfo.autosave || updatedInfo.autosync) {
            persister.persistSync(typeName, id)
        }
    }

    public static func setSilent(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        validator.validateField(typeName, id, field, value)
        store.setFieldValue(typeName, id, field, value)
    }

    public static func enableAutosync(typeName: String, id: String, enabled: Bool): Unit {
        let info = store.getConfigInfo(typeName, id)
        let newInfo = ConfigInfo(
            info.configType,
            info.file,
            info.format,
            info.sources,
            info.fields,
            info.basePath,
            info.autosave,
            enabled,
            info.validate,
            info.stream
        )
        store.updateConfigInfo(typeName, id, newInfo)
        if (enabled) {
            println("ConfigRegistry: autosync 已启用，配置文件: ${info.file}")
        } else {
            println("ConfigRegistry: autosync 已禁用")
        }
    }

    public static func enableAutosave(typeName: String, id: String, enabled: Bool): Unit {
        let info = store.getConfigInfo(typeName, id)
        let newInfo = ConfigInfo(
            info.configType,
            info.file,
            info.format,
            info.sources,
            info.fields,
            info.basePath,
            enabled,
            info.autosync,
            info.validate,
            info.stream
        )
        store.updateConfigInfo(typeName, id, newInfo)
    }

    public static func addInstance(typeName: String, id: String, instance: Any): Unit {
        store.addInstance(typeName, id, instance)
    }

    public static func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit {
        merger.mergeFieldInfos(typeName, id, fields)
    }

    public static func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit {
        merger.mergeSources(typeName, id, sources)
    }

    public static func shutdown(): Unit {
        fileWatcher.stop()
        println("ConfigRegistry: 关闭配置系统")
    }

    public static func startFileChangeWatcher(): Unit {
        fileWatcher.start()
    }

    public static func stopFileChangeWatcher(): Unit {
        fileWatcher.stop()
    }

    public static func getField(typeName: String, id: String, field: String): ?DynamicValue {
        store.getFieldValue(typeName, id, field)
    }

    public static func hasAnyFieldValue(typeName: String, id: String): Bool {
        store.hasAnyFieldValue(typeName, id)
    }

    public static func removeField(typeName: String, id: String, field: String): Bool {
        let existed = store.removeFieldValue(typeName, id, field)
        if (existed) {
            let info = store.getConfigInfo(typeName, id)
            if (info.autosave || info.autosync) {
                persister.persistSync(typeName, id)
            }
        }
        existed
    }

    public static func getConfigInfo(typeName: String, id: String): ConfigInfo {
        store.getConfigInfo(typeName, id)
    }

    public static func mainFileExists(typeName: String, id: String): Bool {
        store.mainFileExists(typeName, id)
    }

    public static func resetFieldValuesFromTopLevelMap(typeName: String, id: String, m: HashMap<String, DynamicValue>): Unit {
        store.resetFieldValuesFromTopLevelMap(typeName, id, m)
    }

    public static func setDiskLoader(loader: ConfigDiskLoader): Unit {
        synchronized(lock) {
            diskLoader = Some(loader)
        }
        fileWatcher.setDiskLoader(loader)
    }

    public static func getFieldValuesSnapshot(typeName: String, id: String): HashMap<String, DynamicValue> {
        store.getFieldValuesSnapshot(typeName, id)
    }

    public static func setPersistHandler(handler: PersistHandler): Unit {
        persister.setPersistHandler(handler)
    }

    public static func getStore(): ConfigStore {
        store
    }

    public static func getPersister(): ConfigPersister {
        persister
    }

    public static func getFileWatcher(): ConfigFileWatcher {
        fileWatcher
    }

    public static func dispatchLoaded(typeName: String, id: String): Unit {
        listenerManager.dispatchLoaded(typeName, id)
    }

    private static func loadFromFile(_: String, info: ConfigInfo): Unit {
        let path = Path(info.file)
        if (!exists(path)) {
            return
        }
        try {
            let bytes = File.readFrom(path)
            let content = String.fromUtf8(bytes)
            println("ConfigRegistry: 已从 ${info.file} 加载配置，内容长度: ${content.size} bytes")
        } catch (e: Exception) {
            println("ConfigRegistry: 加载配置文件失败 ${info.file}: ${e.message}")
        }
    }
}

public class Config {
    public static func register(typeName: String, file: String): Unit {
        registerWithOptions(typeName, file, "default", "", false, true, false, false)
    }

    public static func register(typeName: String, file: String, id: String): Unit {
        registerWithOptions(typeName, file, id, "", false, true, false, false)
    }

    public static func registerFull(
        typeName: String,
        file: String,
        id: String,
        basePath: String,
        format: Format,
        sources: Array<ConfigSource>,
        fields: Array<FieldInfo>,
        autosave: Bool,
        autosync: Bool,
        validate: Bool,
        stream: Bool
    ): Unit {
        let info = ConfigInfo(
            typeName,
            file,
            format,
            sources,
            fields,
            basePath,
            autosave,
            autosync,
            validate,
            stream
        )
        ConfigRegistry.register(typeName, info, id)
    }

    public static func registerWithOptions(
        typeName: String,
        file: String,
        id: String,
        basePath: String,
        autosave: Bool,
        autosync: Bool,
        validate: Bool,
        stream: Bool
    ): Unit {
        registerFull(
            typeName,
            file,
            id,
            basePath,
            Format.AUTO,
            Array<ConfigSource>(),
            Array<FieldInfo>(),
            autosave,
            autosync,
            validate,
            stream
        )
    }

    public static func registerWithOptionsAndFields(
        typeName: String,
        file: String,
        id: String,
        basePath: String,
        autosave: Bool,
        autosync: Bool,
        validate: Bool,
        stream: Bool,
        fields: Array<FieldInfo>
    ): Unit {
        registerFull(
            typeName,
            file,
            id,
            basePath,
            Format.AUTO,
            Array<ConfigSource>(),
            fields,
            autosave,
            autosync,
            validate,
            stream
        )
    }

    public static func registerWithFilesAndOptions(
        typeName: String,
        file: String,
        id: String,
        basePath: String,
        sources: Array<ConfigSource>,
        autosave: Bool,
        autosync: Bool,
        validate: Bool,
        stream: Bool
    ): Unit {
        registerFull(
            typeName,
            file,
            id,
            basePath,
            Format.AUTO,
            sources,
            Array<FieldInfo>(),
            autosave,
            autosync,
            validate,
            stream
        )
    }

    public static func validateField(typeName: String, id: String, field: String): Bool {
        let info = ConfigRegistry.getConfigInfo(typeName, id)
        let fieldValue = ConfigRegistry.getField(typeName, id, field)
        for (fi in info.fields) {
            if (fi.configKey == field || fi.memberName == field) {
                if (fi.verifyPattern.size > 0) {
                    match (fieldValue) {
                        case Some(v) =>
                            try {
                                let re = Regex(fi.verifyPattern)
                                return re.find(v.toString()).isSome()
                            } catch (_: Exception) {
                                return false
                            }
                        case None => return true
                    }
                }
            }
        }
        true
    }

    public static func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit {
        ConfigRegistry.mergeFieldInfos(typeName, id, fields)
    }

    public static func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit {
        ConfigRegistry.mergeSources(typeName, id, sources)
    }

    public static func getField(typeName: String, field: String): ?DynamicValue {
        ConfigRegistry.getField(typeName, "default", field)
    }

    public static func get(typeName: String): Any {
        ConfigRegistry.get(typeName, "default")
    }

    public static func get(typeName: String, id: String): Any {
        ConfigRegistry.get(typeName, id)
    }

    public static func getRef(typeName: String): ConfigRef<Any> {
        getRef(typeName, "default")
    }

    public static func getRef(typeName: String, id: String): ConfigRef<Any> {
        let inst = ConfigRegistry.get(typeName, id)
        ConfigRef<Any>(inst)
    }

    public static func on(typeName: String, listener: BaseConfigListener): BaseConfigListener {
        ConfigRegistry.on(typeName, "default", listener)
    }

    public static func on(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener {
        ConfigRegistry.on(typeName, id, listener)
    }

    public static func off(typeName: String, listener: BaseConfigListener): Unit {
        ConfigRegistry.off(typeName, "default", listener)
    }

    public static func off(typeName: String, id: String, listener: BaseConfigListener): Unit {
        ConfigRegistry.off(typeName, id, listener)
    }

    public static func getField(typeName: String, id: String, field: String): ?DynamicValue {
        ConfigRegistry.getField(typeName, id, field)
    }

    public static func hasAnyFieldValue(typeName: String, id: String): Bool {
        ConfigRegistry.hasAnyFieldValue(typeName, id)
    }

    public static func removeField(typeName: String, id: String, field: String): Bool {
        ConfigRegistry.removeField(typeName, id, field)
    }

    public static func dispatchLoaded(typeName: String): Unit {
        ConfigRegistry.dispatchLoaded(typeName, "default")
    }

    public static func dispatchLoaded(typeName: String, id: String): Unit {
        ConfigRegistry.dispatchLoaded(typeName, id)
    }

    public static func getConfigInfo(typeName: String): ConfigInfo {
        ConfigRegistry.getConfigInfo(typeName, "default")
    }

    public static func getConfigInfo(typeName: String, id: String): ConfigInfo {
        ConfigRegistry.getConfigInfo(typeName, id)
    }

    public static func mainFileExists(typeName: String): Bool {
        ConfigRegistry.mainFileExists(typeName, "default")
    }

    public static func mainFileExists(typeName: String, id: String): Bool {
        ConfigRegistry.mainFileExists(typeName, id)
    }

    public static func fieldAsString(typeName: String, field: String): String {
        match (getField(typeName, field)) {
            case Some(dv) => dv.toString()
            case None => ""
        }
    }

    public static func fieldAsString(typeName: String, id: String, field: String): String {
        match (getField(typeName, id, field)) {
            case Some(dv) => dv.toString()
            case None => ""
        }
    }

    public static func putFieldString(typeName: String, field: String, value: String): Unit {
        set(typeName, "default", field, DVString(value))
    }

    public static func putFieldString(typeName: String, id: String, field: String, value: String): Unit {
        set(typeName, id, field, DVString(value))
    }

    public static func fieldAsInt64(typeName: String, field: String): Int64 {
        match (getField(typeName, field)) {
            case Some(dv) =>
                match (dv.toInt()) {
                    case Some(v) => v
                    case None => 0
                }
            case None => 0
        }
    }

    public static func fieldAsInt64(typeName: String, id: String, field: String): Int64 {
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toInt()) {
                    case Some(v) => v
                    case None => 0
                }
            case None => 0
        }
    }

    public static func putFieldInt64(typeName: String, field: String, value: Int64): Unit {
        set(typeName, "default", field, DVInt(value))
    }

    public static func putFieldInt64(typeName: String, id: String, field: String, value: Int64): Unit {
        set(typeName, id, field, DVInt(value))
    }

    public static func fieldAsBool(typeName: String, field: String): Bool {
        match (getField(typeName, field)) {
            case Some(dv) =>
                match (dv.toBool()) {
                    case Some(v) => v
                    case None => false
                }
            case None => false
        }
    }

    public static func fieldAsBool(typeName: String, id: String, field: String): Bool {
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toBool()) {
                    case Some(v) => v
                    case None => false
                }
            case None => false
        }
    }

    public static func fieldAsArrayString(typeName: String, field: String): Array<String> {
        fieldAsArrayString(typeName, "default", field)
    }

    public static func fieldAsArrayString(typeName: String, id: String, field: String): Array<String> {
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toArray()) {
                    case Some(arr) =>
                        let result = ArrayList<String>()
                        for (item in arr) {
                            result.add(item.toString())
                        }
                        result.toArray()
                    case None =>
                        match (dv.toJsonString()) {
                            case Some(jsonStr) =>
                                try {
                                    let jv = JsonValue.fromStr(jsonStr)
                                    match (jv.kind()) {
                                        case JsArray =>
                                            let result = ArrayList<String>()
                                            for (item in jv.asArray().getItems()) {
                                                result.add(item.toString())
                                            }
                                            return result.toArray()
                                        case _ => ()
                                    }
                                } catch (_: Exception) {
                                    ()
                                }
                                Array<String>()
                            case None => Array<String>()
                        }
                }
            case None => Array<String>()
        }
    }

    public static func fieldAsMapString(typeName: String, field: String): HashMap<String, String> {
        fieldAsMapString(typeName, "default", field)
    }

    public static func fieldAsMapString(typeName: String, id: String, field: String): HashMap<String, String> {
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toMap()) {
                    case Some(m) =>
                        let result = HashMap<String, String>()
                        for ((k, v) in m) {
                            result.add(k, v.toString())
                        }
                        result
                    case None =>
                        match (dv.toJsonString()) {
                            case Some(jsonStr) =>
                                try {
                                    let jv = JsonValue.fromStr(jsonStr)
                                    match (jv.kind()) {
                                        case JsObject =>
                                            let result = HashMap<String, String>()
                                            for ((k, v) in jv.asObject().getFields()) {
                                                result.add(k, v.toString())
                                            }
                                            return result
                                        case _ => ()
                                    }
                                } catch (_: Exception) {
                                    ()
                                }
                                HashMap<String, String>()
                            case None => HashMap<String, String>()
                        }
                }
            case None => HashMap<String, String>()
        }
    }

    public static func putFieldBool(typeName: String, field: String, value: Bool): Unit {
        set(typeName, "default", field, DVBool(value))
    }

    public static func putFieldBool(typeName: String, id: String, field: String, value: Bool): Unit {
        set(typeName, id, field, DVBool(value))
    }

    public static func fieldAsFloat64(typeName: String, field: String): Float64 {
        match (getField(typeName, field)) {
            case Some(dv) =>
                match (dv.toFloat()) {
                    case Some(v) => v
                    case None => 0.0
                }
            case None => 0.0
        }
    }

    public static func putFieldFloat64(typeName: String, field: String, value: Float64): Unit {
        set(typeName, "default", field, DVFloat(value))
    }

    public static func putFieldFloat64(typeName: String, id: String, field: String, value: Float64): Unit {
        set(typeName, id, field, DVFloat(value))
    }

    public static func instances(typeName: String): Array<(String, Any)> {
        ConfigRegistry.instances(typeName)
    }

    public static func info(typeName: String): ConfigMeta {
        ConfigRegistry.info(typeName, "default")
    }

    public static func info(typeName: String, id: String): ConfigMeta {
        ConfigRegistry.info(typeName, id)
    }

    public static func save(typeName: String): Unit {
        ConfigRegistry.save(typeName, "default")
    }

    public static func save(typeName: String, id: String): Unit {
        ConfigRegistry.save(typeName, id)
    }

    public static func reload(typeName: String): Any {
        ConfigRegistry.reload(typeName, "default")
        ConfigRegistry.get(typeName, "default")
    }

    public static func reload(typeName: String, id: String): Any {
        ConfigRegistry.reload(typeName, id)
        ConfigRegistry.get(typeName, id)
    }

    public static func set(typeName: String, field: String, value: Int64): Unit {
        ConfigRegistry.set(typeName, "default", field, DVInt(value))
    }

    public static func set(typeName: String, field: String, value: Int32): Unit {
        ConfigRegistry.set(typeName, "default", field, DVInt(Int64(value)))
    }

    public static func set(typeName: String, field: String, value: Int16): Unit {
        ConfigRegistry.set(typeName, "default", field, DVInt(Int64(value)))
    }

    public static func set(typeName: String, field: String, value: Bool): Unit {
        ConfigRegistry.set(typeName, "default", field, DVBool(value))
    }

    public static func set(typeName: String, field: String, value: Float64): Unit {
        ConfigRegistry.set(typeName, "default", field, DVFloat(value))
    }

    public static func set(typeName: String, field: String, value: Float32): Unit {
        ConfigRegistry.set(typeName, "default", field, DVFloat(Float64(value)))
    }

    public static func set(typeName: String, field: String, value: String): Unit {
        ConfigRegistry.set(typeName, "default", field, DVString(value))
    }

    public static func set(typeName: String, id: String, field: String, value: String): Unit {
        ConfigRegistry.set(typeName, id, field, DVString(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Int64): Unit {
        ConfigRegistry.set(typeName, id, field, DVInt(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Int32): Unit {
        ConfigRegistry.set(typeName, id, field, DVInt(Int64(value)))
    }

    public static func set(typeName: String, id: String, field: String, value: Int16): Unit {
        ConfigRegistry.set(typeName, id, field, DVInt(Int64(value)))
    }

    public static func set(typeName: String, id: String, field: String, value: Bool): Unit {
        ConfigRegistry.set(typeName, id, field, DVBool(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Float64): Unit {
        ConfigRegistry.set(typeName, id, field, DVFloat(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Float32): Unit {
        ConfigRegistry.set(typeName, id, field, DVFloat(Float64(value)))
    }

    public static func set(typeName: String, field: String, value: Array<String>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, field: String, value: Array<Int64>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, field: String, value: Array<Bool>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, field: String, value: Array<Float64>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Array<String>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Array<Int64>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Array<Bool>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, id: String, field: String, value: Array<Float64>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.arrayToDVArray(value))
    }

    public static func set(typeName: String, field: String, value: HashMap<String, String>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, field: String, value: HashMap<String, Int64>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, field: String, value: HashMap<String, Bool>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, field: String, value: HashMap<String, Float64>): Unit {
        ConfigRegistry.set(typeName, "default", field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, id: String, field: String, value: HashMap<String, String>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, id: String, field: String, value: HashMap<String, Int64>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, id: String, field: String, value: HashMap<String, Bool>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, id: String, field: String, value: HashMap<String, Float64>): Unit {
        ConfigRegistry.set(typeName, id, field, Config.mapToDVMap(value))
    }

    public static func set(typeName: String, field: String, value: DynamicValue): Unit {
        ConfigRegistry.set(typeName, "default", field, value)
    }

    public static func set(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        ConfigRegistry.set(typeName, id, field, value)
    }

    public static func setAuto(typeName: String, field: String, value: String): Unit {
        ConfigRegistry.set(typeName, "default", field, parseAutoValue(value))
    }

    public static func setAuto(typeName: String, id: String, field: String, value: String): Unit {
        ConfigRegistry.set(typeName, id, field, parseAutoValue(value))
    }

    private static func parseAutoValue(value: String): DynamicValue {
        let t = value.trimAscii()
        if (t == "true") {
            return DVBool(true)
        }
        if (t == "false") {
            return DVBool(false)
        }
        try {
            return DVInt(Int64.parse(t))
        } catch (_: Exception) {
            ()
        }
        try {
            return DVFloat(Float64.parse(t))
        } catch (_: Exception) {
            ()
        }
        if (t.startsWith("[") && t.endsWith("]")) {
            try {
                let jv = JsonValue.fromStr(t)
                return jsonValueToDynamicValue(jv)
            } catch (_: Exception) {
                ()
            }
        }
        if (t.startsWith("{") && t.endsWith("}")) {
            try {
                let jv = JsonValue.fromStr(t)
                return jsonValueToDynamicValue(jv)
            } catch (_: Exception) {
                ()
            }
        }
        DVString(value)
    }

    private static func jsonValueToDynamicValue(v: JsonValue): DynamicValue {
        match (v.kind()) {
            case JsString =>
                DVString(v.asString().getValue())
            case JsInt =>
                DVInt(v.asInt().getValue())
            case JsFloat =>
                DVFloat(v.asFloat().getValue())
            case JsBool =>
                DVBool(v.asBool().getValue())
            case JsArray =>
                let arr = ArrayList<DynamicValue>()
                for (item in v.asArray().getItems()) {
                    arr.add(jsonValueToDynamicValue(item))
                }
                DVArray(arr.toArray())
            case JsObject =>
                let map = HashMap<String, DynamicValue>()
                for ((k, vv) in v.asObject().getFields()) {
                    map.add(k, jsonValueToDynamicValue(vv))
                }
                DVMap(map)
            case _ => DVString(v.toString())
        }
    }

    public static func arrayToDVArray<T>(arr: Array<T>): DynamicValue where T <: DynamicValue {
        let list = ArrayList<DynamicValue>()
        for (item in arr) {
            list.add(item)
        }
        DVArray(list.toArray())
    }

    public static func arrayToDVArray(arr: Array<String>): DynamicValue {
        let list = ArrayList<DynamicValue>()
        for (item in arr) {
            list.add(DVString(item))
        }
        DVArray(list.toArray())
    }

    public static func arrayToDVArray(arr: Array<Int64>): DynamicValue {
        let list = ArrayList<DynamicValue>()
        for (item in arr) {
            list.add(DVInt(item))
        }
        DVArray(list.toArray())
    }

    public static func arrayToDVArray(arr: Array<Bool>): DynamicValue {
        let list = ArrayList<DynamicValue>()
        for (item in arr) {
            list.add(DVBool(item))
        }
        DVArray(list.toArray())
    }

    public static func arrayToDVArray(arr: Array<Float64>): DynamicValue {
        let list = ArrayList<DynamicValue>()
        for (item in arr) {
            list.add(DVFloat(item))
        }
        DVArray(list.toArray())
    }

    public static func mapToDVMap(m: HashMap<String, DynamicValue>): DynamicValue {
        DVMap(m)
    }

    public static func mapToDVMap(m: HashMap<String, String>): DynamicValue {
        let result = HashMap<String, DynamicValue>()
        for ((k, v) in m) {
            result.add(k, DVString(v))
        }
        DVMap(result)
    }

    public static func mapToDVMap(m: HashMap<String, Int64>): DynamicValue {
        let result = HashMap<String, DynamicValue>()
        for ((k, v) in m) {
            result.add(k, DVInt(v))
        }
        DVMap(result)
    }

    public static func mapToDVMap(m: HashMap<String, Bool>): DynamicValue {
        let result = HashMap<String, DynamicValue>()
        for ((k, v) in m) {
            result.add(k, DVBool(v))
        }
        DVMap(result)
    }

    public static func mapToDVMap(m: HashMap<String, Float64>): DynamicValue {
        let result = HashMap<String, DynamicValue>()
        for ((k, v) in m) {
            result.add(k, DVFloat(v))
        }
        DVMap(result)
    }

    public static func getArray<T>(typeName: String, id: String, field: String, fromJson: (JsonObject) -> T): Array<T> {
        let result = ArrayList<T>()
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toJsonString()) {
                    case Some(jsonStr) =>
                        try {
                            let jv = JsonValue.fromStr(jsonStr)
                            let arr = jv.asArray().getItems()
                            for (item in arr) {
                                result.add(fromJson(item.asObject()))
                            }
                        } catch (_: Exception) {
                        }
                    case None => ()
                }
            case None => ()
        }
        result.toArray()
    }

    public static func getMap<V>(typeName: String, id: String, field: String, fromJson: (JsonObject) -> V): HashMap<String, V> {
        let result = HashMap<String, V>()
        match (getField(typeName, id, field)) {
            case Some(dv) =>
                match (dv.toJsonString()) {
                    case Some(jsonStr) =>
                        try {
                            let jv = JsonValue.fromStr(jsonStr)
                            let obj = jv.asObject()
                            for ((k, v) in obj.getFields()) {
                                let mapVal = fromJson(v.asObject())
                                result.add(k, mapVal)
                            }
                        } catch (_: Exception) {
                        }
                    case None => ()
                }
            case None => ()
        }
        result
    }

    public static func nestedArrayToDV<T>(arr: Array<T>, elemTypeName: String): DynamicValue where T <: ConfigNested<T> {
        let jsonArr = ArrayList<JsonValue>()
        for (item in arr) {
            jsonArr.add(item.toJson())
        }
        DVString(JsonArray(jsonArr.toArray()).toString())
    }

    public static func nestedMapToDV(m: HashMap<String, DynamicValue>): DynamicValue {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, jsonValueToJsonValue(v))
        }
        DVString(JsonObject(jsonObj).toString())
    }

    private static func jsonValueToJsonValue(v: DynamicValue): JsonValue {
        match (v) {
            case dv: DVString => JsonString(dv.value)
            case dv: DVInt => JsonString(dv.value.toString())
            case dv: DVBool => JsonString(dv.value.toString())
            case dv: DVFloat => JsonString(dv.value.toString())
            case dv: DVArray =>
                let arr = ArrayList<JsonValue>()
                for (item in dv.value) {
                    arr.add(jsonValueToJsonValue(item))
                }
                JsonArray(arr.toArray())
            case dv: DVMap =>
                let obj = HashMap<String, JsonValue>()
                for ((k, vv) in dv.value) {
                    obj.add(k, jsonValueToJsonValue(vv))
                }
                JsonObject(obj)
            case _ => JsonString(v.toString())
        }
    }

    public static func nestedMapToDV(m: HashMap<String, String>): DynamicValue {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, JsonString(v))
        }
        DVString(JsonObject(jsonObj).toString())
    }

    public static func nestedMapToDV(m: HashMap<String, Int64>): DynamicValue {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, JsonString(v.toString()))
        }
        DVString(JsonObject(jsonObj).toString())
    }

    public static func nestedMapToDV(m: HashMap<String, Bool>): DynamicValue {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, JsonString(v.toString()))
        }
        DVString(JsonObject(jsonObj).toString())
    }

    public static func nestedMapToDV(m: HashMap<String, Float64>): DynamicValue {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, JsonString(v.toString()))
        }
        DVString(JsonObject(jsonObj).toString())
    }

    /// 泛型版本：V 须实现 ConfigNested<V>，用于自定义嵌套类型 Map 的同步
    public static func nestedMapToDV<V>(m: HashMap<String, V>, keyTypeName: String, valTypeName: String): DynamicValue where V <: ConfigNested<V> {
        let jsonObj = HashMap<String, JsonValue>()
        for ((k, v) in m) {
            jsonObj.add(k, v.toJson())
        }
        DVString(JsonObject(jsonObj).toString())
    }

    public static func setSilent(typeName: String, field: String, value: DynamicValue): Unit {
        ConfigRegistry.setSilent(typeName, "default", field, value)
    }

    public static func setSilent(typeName: String, id: String, field: String, value: DynamicValue): Unit {
        ConfigRegistry.setSilent(typeName, id, field, value)
    }

    public static func enableAutosync(typeName: String, enabled: Bool): Unit {
        ConfigRegistry.enableAutosync(typeName, "default", enabled)
    }

    public static func enableAutosync(typeName: String, id: String, enabled: Bool): Unit {
        ConfigRegistry.enableAutosync(typeName, id, enabled)
    }

    public static func enableAutosave(typeName: String, enabled: Bool): Unit {
        ConfigRegistry.enableAutosave(typeName, "default", enabled)
    }

    public static func enableAutosave(typeName: String, id: String, enabled: Bool): Unit {
        ConfigRegistry.enableAutosave(typeName, id, enabled)
    }

    public static func setDefaults(
        autosave: Option<Bool>,
        autosync: Option<Bool>,
        validate: Option<Bool>
    ): Unit {
        match (autosave) {
            case Some(v) => ConfigDefaults.setAutosave(v)
            case None => ()
        }
        match (autosync) {
            case Some(v) => ConfigDefaults.setAutosync(v)
            case None => ()
        }
        match (validate) {
            case Some(v) => ConfigDefaults.setValidate(v)
            case None => ()
        }
    }

    public static func getDefaults(): GlobalDefaults {
        ConfigDefaults.getDefaults()
    }

    public static func addInstance(typeName: String, instance: Any): Unit {
        ConfigRegistry.addInstance(typeName, "default", instance)
    }

    public static func addInstance(typeName: String, id: String, instance: Any): Unit {
        ConfigRegistry.addInstance(typeName, id, instance)
    }

    public static func shutdown(): Unit {
        ConfigRegistry.shutdown()
    }

    public static func setDiskLoader(loader: ConfigDiskLoader): Unit {
        ConfigRegistry.setDiskLoader(loader)
    }

    public static func startFileChangeWatcher(): Unit {
        ConfigRegistry.startFileChangeWatcher()
    }

    public static func stopFileChangeWatcher(): Unit {
        ConfigRegistry.stopFileChangeWatcher()
    }

    public static func map(typeName: String): ConfigMap {
        ConfigMap(typeName)
    }

    public static func map(typeName: String, id: String): ConfigMap {
        ConfigMap(typeName, id)
    }
}
