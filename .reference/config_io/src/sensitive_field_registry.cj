package config_io

import std.collection.HashSet
import std.sync.Mutex

/// 编译期或启动时显式登记的敏感字段名（按 JSON 对象键名匹配，任意嵌套深度）；ConfigCryptoService 仅据此判定，无内置默认键表。
public class SensitiveFieldRegistry {
    private static let lock: Mutex = Mutex()
    private static let names: HashSet<String> = HashSet<String>()

    /// 登记一个需在落盘前封装、读取时解封的字段名（例如业务专有密钥字段名）。
    public static func register(fieldName: String): Unit {
        synchronized(lock) {
            names.add(fieldName)
        }
    }

    public static func isRegistered(fieldName: String): Bool {
        synchronized(lock) {
            names.contains(fieldName)
        }
    }
}
