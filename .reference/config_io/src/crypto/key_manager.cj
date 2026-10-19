package config_io.crypto

import std.collection.ArrayList
import std.convert.*
import std.env.getVariable
import std.fs.*
import std.random.Random

/// 可选：显式指定密钥文件绝对/相对路径，避免 cwd 与加密时不一致导致找不到旧密钥。
private let ENV_KEY_FILE_PATH: String = "AI_EPOCH_ENCRYPTION_KEY_FILE"

/// 从本地文件加载 32 字节主密钥；否则生成并落盘。
/// 主路径为 `runtimeDataRoot/.encryption_key`，与配置目录同属应用根，不随进程 cwd 漂移。
/// 未设置 runtimeDataRoot 时仍兼容仅使用 cwd 下 `.encryption_key`（测试与旧行为）。
public class KeyManager {
    private static let LEGACY_KEY_FILE: String = ".encryption_key"
    private static var runtimeDataRoot: String = ""
    private static var cachedKey: ?Array<UInt8> = None

    /// 须在创建 ConfigCryptoService / 首次 loadKey 之前调用（例如 main 中在业务 Config 加载之前）
    /// 若 `root` 对应目录已存在，规范化为绝对路径，减少「相对路径随 cwd 变化指向不同文件」的问题。
    public static func setRuntimeDataRoot(root: String): Unit {
        let trimmed = root.trimAscii()
        if (trimmed.size == 0) {
            runtimeDataRoot = ""
            cachedKey = None
            return
        }
        try {
            let p = Path(trimmed)
            if (exists(p)) {
                runtimeDataRoot = canonicalize(p).toString()
            } else {
                runtimeDataRoot = trimmed
            }
        } catch (_: Exception) {
            runtimeDataRoot = trimmed
        }
        cachedKey = None
    }

    private static func primaryKeyPath(): String {
        if (runtimeDataRoot.size > 0) {
            return runtimeDataRoot + "/.encryption_key"
        }
        LEGACY_KEY_FILE
    }

    public static func generateKey(): Array<UInt8> {
        let key = ArrayList<UInt8>()
        let r = Random()
        var i: Int64 = 0
        while (i < 32) {
            key.add(r.nextUInt8())
            i = i + 1
        }
        key.toArray()
    }

    public static func loadKeyFromFile(keyPath: String): ?Array<UInt8> {
        try {
            let bytes = File.readFrom(Path(keyPath))
            let content = String.fromUtf8(bytes).trimAscii()
            if (content.size == 64) {
                Some(hexToKey32(content))
            } else {
                None
            }
        } catch (_: Exception) {
            None
        }
    }

    public static func saveKeyToFile(key: Array<UInt8>, keyPath: String): Unit {
        File.writeTo(Path(keyPath), keyToHex(key).toArray())
    }

    public static func loadKey(): Array<UInt8> {
        match (cachedKey) {
            case Some(k) => return k
            case None => ()
        }
        let key = loadKeyUncached()
        cachedKey = Some(key)
        key
    }

    private static func loadKeyUncached(): Array<UInt8> {
        match (getVariable(ENV_KEY_FILE_PATH)) {
            case Some(raw) =>
                let pth = raw.trimAscii()
                if (pth.size > 0) {
                    match (loadKeyFromFile(pth)) {
                        case Some(k) => return k
                        case None => println("[KeyManager] 环境变量 ${ENV_KEY_FILE_PATH} 指向的密钥无效或不可读: ${pth}")
                    }
                }
            case None => ()
        }
        let primary = primaryKeyPath()
        match (loadKeyFromFile(primary)) {
            case Some(k) => return k
            case None => ()
        }
        if (runtimeDataRoot.size > 0 && primary != LEGACY_KEY_FILE) {
            match (loadKeyFromFile(LEGACY_KEY_FILE)) {
                case Some(k) =>
                    try {
                        saveKeyToFile(k, primary)
                        println("[KeyManager] 已从 ${LEGACY_KEY_FILE} 迁移密钥到 ${primary}")
                    } catch (_: Exception) {
                        println("[KeyManager] 迁移密钥到 ${primary} 失败，将直接使用 ${LEGACY_KEY_FILE}")
                    }
                    return k
                case None => ()
            }
        }
        match (loadKeyFromFile(LEGACY_KEY_FILE)) {
            case Some(k) => return k
            case None => ()
        }
        let newKey = generateKey()
        let target = primary
        try {
            saveKeyToFile(newKey, target)
            println("[KeyManager] 已生成新密钥并写入 ${target}，请妥善备份")
        } catch (_: Exception) {
            saveKeyToFile(newKey, LEGACY_KEY_FILE)
            println("[KeyManager] 已生成新密钥并写入 ${LEGACY_KEY_FILE}，请妥善备份")
        }
        newKey
    }

    private static func keyToHex(key: Array<UInt8>): String {
        var s = ""
        for (b in key) {
            let hi = Int64((b >> 4) & 0x0fu8)
            let lo = Int64(b & 0x0fu8)
            s = s + hi.format("x") + lo.format("x")
        }
        s
    }
}

private func hexToKey32(hexKey: String): Array<UInt8> {
    let key = ArrayList<UInt8>()
    var i: Int64 = 0
    while (i < hexKey.size) {
        let byte = hexCharPairToByte(hexKey[i], hexKey[i + 1])
        key.add(byte)
        i = i + 2
    }
    key.toArray()
}

private func hexCharPairToByte(c1: UInt8, c2: UInt8): UInt8 {
    hexCharToNibble(c1) * 16u8 + hexCharToNibble(c2)
}

private func hexCharToNibble(c: UInt8): UInt8 {
    if (c >= '0'.toArray()[0] && c <= '9'.toArray()[0]) {
        return c - '0'.toArray()[0]
    }
    if (c >= 'a'.toArray()[0] && c <= 'f'.toArray()[0]) {
        return c - 'a'.toArray()[0] + 10u8
    }
    if (c >= 'A'.toArray()[0] && c <= 'F'.toArray()[0]) {
        return c - 'A'.toArray()[0] + 10u8
    }
    throw Exception("无效的十六进制字符")
}
