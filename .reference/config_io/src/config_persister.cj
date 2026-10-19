package config_io

import std.sync.*

public class ConfigPersister {
    private let lock: Mutex = Mutex()
    private let store: ConfigStore
    private var persistHandler: ?PersistHandler = None

    public init(store: ConfigStore) {
        this.store = store
    }

    public func setPersistHandler(handler: PersistHandler): Unit {
        synchronized(lock) {
            persistHandler = Some(handler)
        }
    }

    public func persistSync(typeName: String, id: String): Unit {
        let key = "${typeName}:${id}"
        let info = store.getConfigInfo(typeName, id)
        let fieldMap = store.getFieldValuesSnapshot(typeName, id)
        let handler = synchronized(lock) {
            persistHandler
        }
        try {
            match (handler) {
                case Some(h) =>
                    h.persist(key, info, fieldMap)
                case None =>
                    throw ConfigException(
                        "SAVE_FAILED",
                        "未设置 PersistHandler，请调用 installYamlCryptoPersistHandler() 后再持久化"
                    )
            }
            println("ConfigPersister: 配置已保存到 ${info.file}")
        } catch (e: Exception) {
            println("ConfigPersister: 保存配置失败 ${info.file}: ${e.message}")
        }
    }
}
