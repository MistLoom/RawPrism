/*
 * delete_persist_tests — 删除持久化验证模块
 *
 * 验证修复：removeField 后 save+reload，字段从文件移除且不再恢复。
 * 覆盖 7 种格式（JSON/YAML/TOML/INI/XML/ENV/CONF）的前后读写验证。
 *
 * 测试节：
 *   A-G. 全格式删除持久化（每格式 4 断言 = 28 断言）
 *       1. 删除前基线：字段存在且值正确
 *       2. removeField + save 后文件中字段值已移除
 *       3. reload 后字段不再恢复（值为空）
 *       4. 同级其他字段不受影响
 *   H. 边界场景（5 断言）
 *       H1. 幂等删除（删除不存在的字段不影响文件）
 *       H2. 连续删除两个字段
 *       H3. 删除后重新 storeField 恢复
 */

package config_test.delete_persist_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ===== 初始内容常量 =====

private let DP_INIT_JSON = "{\"delField\":\"json-del\",\"keepField\":\"json-keep\"}"
private let DP_INIT_YAML = "delField: yaml-del\nkeepField: yaml-keep\n"
private let DP_INIT_TOML = "delField = toml-del\nkeepField = toml-keep\n"
private let DP_INIT_INI = "delField=ini-del\nkeepField=ini-keep\n"
private let DP_INIT_XML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<configuration>\n  <entry key=\"delField\">xml-del</entry>\n  <entry key=\"keepField\">xml-keep</entry>\n</configuration>\n"
private let DP_INIT_ENV = "delField=env-del\nkeepField=env-keep\n"
private let DP_INIT_CONF = "delField=conf-del\nkeepField=conf-keep\n"

// ===== @config 类（7 格式） =====

@config[file = "config/delete_persist/dp_json.json", id = "dpjson", autosync = false]
class DpJsonConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_yaml.yaml", id = "dpyaml", autosync = false]
class DpYamlConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_toml.toml", id = "dptoml", autosync = false]
class DpTomlConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_ini.ini", id = "dpini", autosync = false]
class DpIniConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_xml.xml", id = "dpxml", autosync = false]
class DpXmlConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_env.env", id = "dpenv", autosync = false]
class DpEnvConfig {
    var delField: String = ""
    var keepField: String = ""
}

@config[file = "config/delete_persist/dp_conf.conf", id = "dpconf", autosync = false]
class DpConfConfig {
    var delField: String = ""
    var keepField: String = ""
}

// ===== 辅助函数 =====

private func readFileText(path: String): String {
    if (!exists(path)) {
        return ""
    }
    let data = File.readFrom(path)
    String.fromUtf8(data)
}

private func restoreDpFiles(): Unit {
    File.writeTo("config/delete_persist/dp_json.json", DP_INIT_JSON.toArray())
    File.writeTo("config/delete_persist/dp_yaml.yaml", DP_INIT_YAML.toArray())
    File.writeTo("config/delete_persist/dp_toml.toml", DP_INIT_TOML.toArray())
    File.writeTo("config/delete_persist/dp_ini.ini", DP_INIT_INI.toArray())
    File.writeTo("config/delete_persist/dp_xml.xml", DP_INIT_XML.toArray())
    File.writeTo("config/delete_persist/dp_env.env", DP_INIT_ENV.toArray())
    File.writeTo("config/delete_persist/dp_conf.conf", DP_INIT_CONF.toArray())
}

/// 单格式删除持久化验证：删除前 → 删除后文件 → reload → keepField 不受影响
/// 返回 (pass, fail)
private func verifyDeletePersist(
    label: String,
    typeName: String,
    id: String,
    filePath: String,
    delVal: String,
    keepVal: String
): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    // 1. 删除前基线：字段存在且值正确
    let baselineDel = Config.fieldAsString(typeName, id, "delField")
    if (assertEq("${label} 删除前delField存在=${delVal}", baselineDel, delVal)) { pass += 1 } else { fail += 1 }

    // 2. removeField + save
    Config.removeField(typeName, id, "delField")
    Config.save(typeName, id)

    // 3. 验证文件中 delVal 已移除
    let fileAfterDelete = readFileText(filePath)
    if (assertTrue("${label} save后文件已移除${delVal}", !fileAfterDelete.contains(delVal))) { pass += 1 } else { fail += 1 }

    // 4. reload 后字段不再恢复
    Config.reload(typeName, id)
    let afterReload = Config.fieldAsString(typeName, id, "delField")
    if (assertEq("${label} reload后delField不再恢复=空", afterReload, "")) { pass += 1 } else { fail += 1 }

    // 5. keepField 不受影响
    let keepAfter = Config.fieldAsString(typeName, id, "keepField")
    if (assertEq("${label} keepField不受影响=${keepVal}", keepAfter, keepVal)) { pass += 1 } else { fail += 1 }

    (pass, fail)
}

// ===== 测试入口 =====

public func runDeletePersistTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    section("删除持久化验证 — 7 格式前后读写")

    // 恢复全部初始文件
    restoreDpFiles()

    // A. JSON
    section("A. JSON 删除持久化")
    Config.reload("DpJsonConfig", "dpjson")
    let (jp, jf) = verifyDeletePersist("JSON", "DpJsonConfig", "dpjson", "config/delete_persist/dp_json.json", "json-del", "json-keep")
    pass += jp
    fail += jf

    // B. YAML
    section("B. YAML 删除持久化")
    restoreDpFiles()
    Config.reload("DpYamlConfig", "dpyaml")
    let (yp, yf) = verifyDeletePersist("YAML", "DpYamlConfig", "dpyaml", "config/delete_persist/dp_yaml.yaml", "yaml-del", "yaml-keep")
    pass += yp
    fail += yf

    // C. TOML
    section("C. TOML 删除持久化")
    restoreDpFiles()
    Config.reload("DpTomlConfig", "dptoml")
    let (tp, tf) = verifyDeletePersist("TOML", "DpTomlConfig", "dptoml", "config/delete_persist/dp_toml.toml", "toml-del", "toml-keep")
    pass += tp
    fail += tf

    // D. INI
    section("D. INI 删除持久化")
    restoreDpFiles()
    Config.reload("DpIniConfig", "dpini")
    let (ip, if_) = verifyDeletePersist("INI", "DpIniConfig", "dpini", "config/delete_persist/dp_ini.ini", "ini-del", "ini-keep")
    pass += ip
    fail += if_

    // E. XML
    section("E. XML 删除持久化")
    restoreDpFiles()
    Config.reload("DpXmlConfig", "dpxml")
    let (xp, xf) = verifyDeletePersist("XML", "DpXmlConfig", "dpxml", "config/delete_persist/dp_xml.xml", "xml-del", "xml-keep")
    pass += xp
    fail += xf

    // F. ENV
    section("F. ENV 删除持久化")
    restoreDpFiles()
    Config.reload("DpEnvConfig", "dpenv")
    let (ep, ef) = verifyDeletePersist("ENV", "DpEnvConfig", "dpenv", "config/delete_persist/dp_env.env", "env-del", "env-keep")
    pass += ep
    fail += ef

    // G. CONF
    section("G. CONF 删除持久化")
    restoreDpFiles()
    Config.reload("DpConfConfig", "dpconf")
    let (cp, cf) = verifyDeletePersist("CONF", "DpConfConfig", "dpconf", "config/delete_persist/dp_conf.conf", "conf-del", "conf-keep")
    pass += cp
    fail += cf

    // H. 边界场景
    section("H. 边界场景")

    // H1. 幂等删除：删除不存在的字段，文件不受影响
    restoreDpFiles()
    Config.reload("DpJsonConfig", "dpjson")
    Config.removeField("DpJsonConfig", "dpjson", "nonExistent")
    Config.save("DpJsonConfig", "dpjson")
    Config.reload("DpJsonConfig", "dpjson")
    if (assertEq("H1 幂等删除后keepField不受影响=json-keep", Config.fieldAsString("DpJsonConfig", "dpjson", "keepField"), "json-keep")) { pass += 1 } else { fail += 1 }

    // H2. 连续删除两个字段
    restoreDpFiles()
    Config.reload("DpJsonConfig", "dpjson")
    Config.removeField("DpJsonConfig", "dpjson", "delField")
    Config.save("DpJsonConfig", "dpjson")
    Config.removeField("DpJsonConfig", "dpjson", "keepField")
    Config.save("DpJsonConfig", "dpjson")
    Config.reload("DpJsonConfig", "dpjson")
    if (assertEq("H2 连续删除后delField=空", Config.fieldAsString("DpJsonConfig", "dpjson", "delField"), "")) { pass += 1 } else { fail += 1 }
    if (assertEq("H2 连续删除后keepField=空", Config.fieldAsString("DpJsonConfig", "dpjson", "keepField"), "")) { pass += 1 } else { fail += 1 }

    // H3. 删除后重新 storeField 恢复
    restoreDpFiles()
    Config.reload("DpJsonConfig", "dpjson")
    Config.removeField("DpJsonConfig", "dpjson", "delField")
    Config.save("DpJsonConfig", "dpjson")
    Config.set("DpJsonConfig", "dpjson", "delField", DVString("restored-val"))
    Config.save("DpJsonConfig", "dpjson")
    Config.reload("DpJsonConfig", "dpjson")
    if (assertEq("H3 删除后恢复delField=restored-val", Config.fieldAsString("DpJsonConfig", "dpjson", "delField"), "restored-val")) { pass += 1 } else { fail += 1 }
    if (assertEq("H3 恢复后keepField仍存在=json-keep", Config.fieldAsString("DpJsonConfig", "dpjson", "keepField"), "json-keep")) { pass += 1 } else { fail += 1 }

    // 恢复文件
    restoreDpFiles()

    report(pass, fail)
    (pass, fail)
}
