package config_test.encrypt_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ============================================================
// 7 个 @config 类（每个格式一个，autosync = false）
//
// 设计说明：
//   - JSON / YAML / XML：password 使用自动字段识别（configKey = "password"），
//     文件中使用顶层 password 键。这样加密往返（R4.4/R4.5）时，
//     persist 处理器将 password 放在 JSON 顶层，encryptJsonValue 能匹配
//     SensitiveFieldRegistry 中注册的 "password" 键，正确触发加密。
//   - TOML / INI / ENV / CONF：password 使用 @key[key = "database.password"]，
//     文件中使用扁平键 database.password。这些格式 persist 时使用扁平 put，
//     键 "database.password" 直接写入 JsonObject 顶层，encryptJsonValue 能匹配。
// ============================================================

@config[file = "config/encrypt/enc_json.json", id = "encjson", autosync = false]
class EncJsonConfig {
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    @key[key = "apiKey"]
    var apiKey: String = ""
    @key[key = "normal"]
    var normal: String = ""
}

@config[file = "config/encrypt/enc_yaml.yaml", id = "encyaml", autosync = false]
class EncYamlConfig {
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    var apiKey: String = ""
    var normal: String = ""
}

@config[file = "config/encrypt/enc_toml.toml", id = "enctoml", autosync = false]
class EncTomlConfig {
    @key[key = "database.password"]
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    @key[key = "apiKey"]
    var apiKey: String = ""
    @key[key = "normal"]
    var normal: String = ""
}

@config[file = "config/encrypt/enc_ini.ini", id = "encini", autosync = false]
class EncIniConfig {
    @key[key = "database.password"]
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    @key[key = "apiKey"]
    var apiKey: String = ""
    @key[key = "normal"]
    var normal: String = ""
}

@config[file = "config/encrypt/enc_xml.xml", id = "encxml", autosync = false]
class EncXmlConfig {
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    var apiKey: String = ""
    var normal: String = ""
}

@config[file = "config/encrypt/enc_env.env", id = "encenv", autosync = false]
class EncEnvConfig {
    @key[key = "database.password"]
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    @key[key = "apiKey"]
    var apiKey: String = ""
    @key[key = "normal"]
    var normal: String = ""
}

@config[file = "config/encrypt/enc_conf.conf", id = "encconf", autosync = false]
class EncConfConfig {
    @key[key = "database.password"]
    @encrypt[algorithm = "sym:enc:v1"]
    var password: String = ""
    @key[key = "apiKey"]
    var apiKey: String = ""
    @key[key = "normal"]
    var normal: String = ""
}

// ============================================================
// 辅助函数
// ============================================================

private func readFileText(path: String): String {
    if (!exists(Path(path))) {
        return ""
    }
    let data = File.readFrom(Path(path))
    String.fromUtf8(data)
}

private func buildInitFiles(): HashMap<String, String> {
    let m = HashMap<String, String>()
    m.add("config/encrypt/enc_json.json", "{\"password\":\"json-enc-secret\",\"apiKey\":\"json-api-key\",\"normal\":\"json-normal\"}\n")
    m.add("config/encrypt/enc_yaml.yaml", "password: \"yaml-enc-secret\"\napiKey: yaml-api-key\nnormal: yaml-normal\n")
    m.add("config/encrypt/enc_toml.toml", "database.password = \"toml-enc-secret\"\napiKey = \"toml-api-key\"\nnormal = \"toml-normal\"\n")
    m.add("config/encrypt/enc_ini.ini", "[database]\npassword=ini-enc-secret\n[app]\napiKey=ini-api-key\nnormal=ini-normal\n")
    m.add("config/encrypt/enc_xml.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<configuration>\n  <entry key=\"password\">xml-enc-secret</entry>\n  <entry key=\"apiKey\">xml-api-key</entry>\n  <entry key=\"normal\">xml-normal</entry>\n</configuration>\n")
    m.add("config/encrypt/enc_env.env", "database.password=env-enc-secret\napiKey=env-api-key\nnormal=env-normal\n")
    m.add("config/encrypt/enc_conf.conf", "database.password=conf-enc-secret\napiKey=conf-api-key\nnormal=conf-normal\n")
    m
}

private let INIT_FILES: HashMap<String, String> = buildInitFiles()

private func restoreEncFiles(): Unit {
    for ((path, content) in INIT_FILES) {
        let bytes = content.toArray()
        File.writeTo(Path(path), bytes)
    }
    Config.reload("EncJsonConfig", "encjson")
    Config.reload("EncYamlConfig", "encyaml")
    Config.reload("EncTomlConfig", "enctoml")
    Config.reload("EncIniConfig", "encini")
    Config.reload("EncXmlConfig", "encxml")
    Config.reload("EncEnvConfig", "encenv")
    Config.reload("EncConfConfig", "encconf")
}

// ============================================================
// 测试节
// ============================================================

public func runEncryptTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    restoreEncFiles()

    // --- R4.1 全格式透明解密读取 ---
    section("R4.1 全格式透明解密读取")

    let jsonPass = Config.fieldAsString("EncJsonConfig", "encjson", "password")
    if (assertEq("JSON透明解密password", jsonPass, "json-enc-secret")) { pass += 1 } else { fail += 1 }

    let yamlPass = Config.fieldAsString("EncYamlConfig", "encyaml", "password")
    if (assertEq("YAML透明解密password", yamlPass, "yaml-enc-secret")) { pass += 1 } else { fail += 1 }

    let tomlPass = Config.fieldAsString("EncTomlConfig", "enctoml", "database.password")
    if (assertEq("TOML透明解密password", tomlPass, "toml-enc-secret")) { pass += 1 } else { fail += 1 }

    let iniPass = Config.fieldAsString("EncIniConfig", "encini", "database.password")
    if (assertEq("INI透明解密password", iniPass, "ini-enc-secret")) { pass += 1 } else { fail += 1 }

    let xmlPass = Config.fieldAsString("EncXmlConfig", "encxml", "password")
    if (assertEq("XML透明解密password", xmlPass, "xml-enc-secret")) { pass += 1 } else { fail += 1 }

    let envPass = Config.fieldAsString("EncEnvConfig", "encenv", "database.password")
    if (assertEq("ENV透明解密password", envPass, "env-enc-secret")) { pass += 1 } else { fail += 1 }

    let confPass = Config.fieldAsString("EncConfConfig", "encconf", "database.password")
    if (assertEq("CONF透明解密password", confPass, "conf-enc-secret")) { pass += 1 } else { fail += 1 }

    // --- R4.2 敏感字段注册验证 ---
    section("R4.2 敏感字段注册验证")

    if (assertTrue("JSON password已注册敏感", SensitiveFieldRegistry.isRegistered("password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("YAML password已注册敏感", SensitiveFieldRegistry.isRegistered("password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("TOML database.password已注册敏感", SensitiveFieldRegistry.isRegistered("database.password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("INI database.password已注册敏感", SensitiveFieldRegistry.isRegistered("database.password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("XML password已注册敏感", SensitiveFieldRegistry.isRegistered("password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("ENV database.password已注册敏感", SensitiveFieldRegistry.isRegistered("database.password"))) { pass += 1 } else { fail += 1 }
    if (assertTrue("CONF database.password已注册敏感", SensitiveFieldRegistry.isRegistered("database.password"))) { pass += 1 } else { fail += 1 }

    // --- R4.3 非加密字段不注册敏感 ---
    section("R4.3 非加密字段不注册敏感")

    if (assertFalse("apiKey未注册敏感", SensitiveFieldRegistry.isRegistered("apiKey"))) { pass += 1 } else { fail += 1 }
    if (assertFalse("normal未注册敏感", SensitiveFieldRegistry.isRegistered("normal"))) { pass += 1 } else { fail += 1 }

    // --- R4.4 加密往返 sync→save→reload ---
    section("R4.4 加密往返 sync→save→reload (JSON)")

    restoreEncFiles()

    let inst = EncJsonConfig.ref().get()
    inst.password = "roundtrip-secret"
    inst.sync()
    Config.save("EncJsonConfig", "encjson")

    let fileContent44 = readFileText("config/encrypt/enc_json.json")
    if (assertTrue("加密后文件含ENC:v1:前缀", fileContent44.indexOf("ENC:v1:").isSome())) { pass += 1 } else { fail += 1 }
    if (assertFalse("加密后文件不含明文roundtrip-secret", fileContent44.indexOf("roundtrip-secret").isSome())) { pass += 1 } else { fail += 1 }

    Config.reload("EncJsonConfig", "encjson")
    let restored44 = Config.fieldAsString("EncJsonConfig", "encjson", "password")
    if (assertEq("reload后解密还原password", restored44, "roundtrip-secret")) { pass += 1 } else { fail += 1 }

    // --- R4.5 加密字段 storeField 往返 ---
    section("R4.5 加密字段 storeField 往返 (JSON)")

    restoreEncFiles()

    EncJsonConfig.storeField("password", "storefield-secret")
    Config.save("EncJsonConfig", "encjson")

    let fileContent45 = readFileText("config/encrypt/enc_json.json")
    if (assertTrue("storeField后文件含ENC:v1:前缀", fileContent45.indexOf("ENC:v1:").isSome())) { pass += 1 } else { fail += 1 }

    Config.reload("EncJsonConfig", "encjson")
    let restored45 = Config.fieldAsString("EncJsonConfig", "encjson", "password")
    if (assertEq("storeField reload后解密还原password", restored45, "storefield-secret")) { pass += 1 } else { fail += 1 }

    // 恢复所有配置文件
    restoreEncFiles()

    report(pass, fail)
    (pass, fail)
}
