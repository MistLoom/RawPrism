/*
 * sync_tests — 同步机制测试模块
 *
 * 覆盖需求：
 *   R8（同步机制）：sync() 更新注册表不写文件 / Config.save() 写文件 /
 *                   syncField 单字段同步 / getField,setField 动态读写 /
 *                   全格式 sync→save→reload 往返 / 类型保持 / 加密往返 /
 *                   Array<String> 持久化 / 边界场景 / 外部文件修改 reload
 *
 * 测试节：
 *   A. 初始加载验证（R8.7）
 *   B. sync() 更新注册表不写文件（R8.1, R8.4）
 *   C. Config.save() 写文件（R8.2）
 *   D. syncField 单字段同步（R8.5）
 *   E. getField/setField 动态读写（R8.6）
 *   F. 全格式 sync→save→reload 往返（R8.8）
 *   G. 类型保持往返（R8.10）
 *   H. @encrypt 字段文件同步往返（R4.4 关联）
 *   I. Array<String> 持久化（R8.10 关联）
 *   J. 边界场景（R8.11-R8.15）
 *   K. 外部文件修改 reload（R8.16）
 */

package config_test.sync_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ===== 初始内容常量 =====

private let INIT_SYNC_JSON = "{\"app\":{\"name\":\"sync-test-app\",\"version\":\"1.0.0\"},\"server\":{\"port\":\"8080\"},\"enabled\":true,\"maxRetries\":3,\"ratio\":0.5,\"tags\":[\"original\",\"test\"],\"secret\":\"sync-test-secret\"}"
private let INIT_JSON_SYNC = "{\"app\":{\"name\":\"json-sync-app\"}}"
private let INIT_YAML_SYNC = "appName: yaml-sync-app\nserverPort: \"9090\"\n"
private let INIT_TOML_SYNC = "app.name = toml-sync-app\nserver.port = \"7070\"\n"
private let INIT_INI_SYNC = "[app]\nname=ini-sync-app\n[server]\nport=6060\n"
private let INIT_XML_SYNC = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<configuration>\n  <entry key=\"appName\">xml-sync-app</entry>\n  <entry key=\"serverPort\">5050</entry>\n</configuration>\n"
private let INIT_ENV_SYNC = "app.name=env-sync-app\nserver.port=4040\n"
private let INIT_CONF_SYNC = "app.name=conf-sync-app\nserver.port=3030\n"

// ===== @config 类定义 =====

@config[file = "config/sync/sync_test.json", id = "synctest", autosync = false]
class SyncTestConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    var enabled: Bool = false
    var maxRetries: Int64 = 0
    var ratio: Float64 = 0.0
    var tags: Array<String> = Array<String>()
    @encrypt[algorithm = "sym:enc:v1"]
    var secret: String = ""
}

@config[file = "config/sync/json_sync.json", id = "jsonsync", autosync = false]
class JsonSyncConfig {
    @key[key = "app.name"]
    var appName: String = ""
}

@config[file = "config/sync/yaml_sync.yaml", id = "yamlsync", autosync = false]
class YamlSyncConfig {
    var appName: String = ""
    var serverPort: String = "0"
}

@config[file = "config/sync/toml_sync.toml", id = "tomlsync", autosync = false]
class TomlSyncConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/sync/ini_sync.ini", id = "inisync", autosync = false]
class IniSyncConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/sync/xml_sync.xml", id = "xmlsync", autosync = false]
class XmlSyncConfig {
    var appName: String = ""
    var serverPort: String = "0"
}

@config[file = "config/sync/env_sync.env", id = "envsync", autosync = false]
class EnvSyncConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/sync/conf_sync.conf", id = "confsync", autosync = false]
class ConfSyncConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

// ===== 辅助函数 =====

private func readFileText(path: String): String {
    if (!exists(path)) {
        return ""
    }
    let data = File.readFrom(path)
    String.fromUtf8(data)
}

private func restoreSyncFile(): Unit {
    File.writeTo("config/sync/sync_test.json", INIT_SYNC_JSON.toArray())
    Config.reload("SyncTestConfig", "synctest")
}

private func restoreAllSyncFiles(): Unit {
    File.writeTo("config/sync/sync_test.json", INIT_SYNC_JSON.toArray())
    File.writeTo("config/sync/json_sync.json", INIT_JSON_SYNC.toArray())
    File.writeTo("config/sync/yaml_sync.yaml", INIT_YAML_SYNC.toArray())
    File.writeTo("config/sync/toml_sync.toml", INIT_TOML_SYNC.toArray())
    File.writeTo("config/sync/ini_sync.ini", INIT_INI_SYNC.toArray())
    File.writeTo("config/sync/xml_sync.xml", INIT_XML_SYNC.toArray())
    File.writeTo("config/sync/env_sync.env", INIT_ENV_SYNC.toArray())
    File.writeTo("config/sync/conf_sync.conf", INIT_CONF_SYNC.toArray())
    Config.reload("SyncTestConfig", "synctest")
    Config.reload("JsonSyncConfig", "jsonsync")
    Config.reload("YamlSyncConfig", "yamlsync")
    Config.reload("TomlSyncConfig", "tomlsync")
    Config.reload("IniSyncConfig", "inisync")
    Config.reload("XmlSyncConfig", "xmlsync")
    Config.reload("EnvSyncConfig", "envsync")
    Config.reload("ConfSyncConfig", "confsync")
}

// ===== 测试入口 =====

public func runSyncTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    restoreAllSyncFiles()

    // --------------------------------------------------
    // A. 初始加载验证（R8.7）
    //    验证 SyncTestConfig 的 8 个字段初始值正确
    // --------------------------------------------------
    section("A. 初始加载验证（R8.7）")
    let acfg = SyncTestConfig.ref().get()
    if (assertEq("A appName 初始值", acfg.appName, "sync-test-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("A appVersion 初始值", acfg.appVersion, "1.0.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("A serverPort 初始值", acfg.serverPort, "8080")) { pass += 1 } else { fail += 1 }
    if (assertEq("A enabled 初始值", acfg.enabled, true)) { pass += 1 } else { fail += 1 }
    if (assertEq("A maxRetries 初始值", acfg.maxRetries, 3)) { pass += 1 } else { fail += 1 }
    if (assertTrue("A ratio 初始值 = 0.5", acfg.ratio > 0.49 && acfg.ratio < 0.51)) { pass += 1 } else { fail += 1 }
    if (assertTrue("A tags 初始 size = 2", acfg.tags.size == 2)) { pass += 1 } else { fail += 1 }
    if (assertEq("A secret 初始值（透明解密）", acfg.secret, "sync-test-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // B. sync() 更新注册表不写文件（R8.1, R8.4）
    // --------------------------------------------------
    section("B. sync() 更新注册表不写文件（R8.1, R8.4）")
    restoreSyncFile()
    let beforeB = readFileText("config/sync/sync_test.json")
    if (assertTrue("B 初始文件含 sync-test-app", beforeB.indexOf("sync-test-app").isSome())) { pass += 1 } else { fail += 1 }
    let instB = SyncTestConfig.ref().get()
    instB.appName = "sync-no-write"
    instB.sync()
    if (assertEq("B sync 后注册表 app.name 已更新", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "sync-no-write")) { pass += 1 } else { fail += 1 }
    if (assertFalse("B sync 后文件未变（不含 sync-no-write）", readFileText("config/sync/sync_test.json").indexOf("sync-no-write").isSome())) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // C. Config.save() 写文件（R8.2）
    // --------------------------------------------------
    section("C. Config.save() 写文件（R8.2）")
    restoreSyncFile()
    let instC = SyncTestConfig.ref().get()
    instC.appName = "save-write-val"
    instC.sync()
    if (assertEq("C save 前注册表 app.name", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "save-write-val")) { pass += 1 } else { fail += 1 }
    Config.save("SyncTestConfig", "synctest")
    if (assertTrue("C save 后文件含 save-write-val", readFileText("config/sync/sync_test.json").indexOf("save-write-val").isSome())) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // D. syncField 单字段同步（R8.5）
    // --------------------------------------------------
    section("D. syncField 单字段同步（R8.5）")
    restoreSyncFile()
    let instD = SyncTestConfig.ref().get()
    instD.appName = "field-sync-val"
    instD.appVersion = "9.9.9"
    instD.syncField("appName")
    if (assertEq("D syncField 后 app.name 已更新", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "field-sync-val")) { pass += 1 } else { fail += 1 }
    if (assertEq("D app.version 注册表未更新（仍为旧值）", Config.fieldAsString("SyncTestConfig", "synctest", "app.version"), "1.0.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("D ref 后实例 appVersion 为注册表旧值", SyncTestConfig.ref().get().appVersion, "1.0.0")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // E. getField/setField 动态读写（R8.6）
    // --------------------------------------------------
    section("E. getField/setField 动态读写（R8.6）")
    restoreSyncFile()
    let instE = SyncTestConfig.ref().get()
    instE.setField("app.name", "dynamic-val")
    if (assertEq("E getField(app.name) 动态读", instE.getField("app.name"), "dynamic-val")) { pass += 1 } else { fail += 1 }
    if (assertEq("E Config.fieldAsString 注册表值", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "dynamic-val")) { pass += 1 } else { fail += 1 }
    if (assertEq("E ref().get().appName 反映注册表", SyncTestConfig.ref().get().appName, "dynamic-val")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // F. 全格式 sync→save→reload 往返（R8.8）
    //    7 格式各 3 个断言（共 21）
    // --------------------------------------------------
    section("F. 全格式 sync→save→reload 往返（R8.8）")
    restoreAllSyncFiles()

    // F.1 JSON
    let instFJ = JsonSyncConfig.ref().get()
    instFJ.appName = "json-sync-new"
    instFJ.sync()
    if (assertEq("F JSON sync 后注册表 app.name", Config.fieldAsString("JsonSyncConfig", "jsonsync", "app.name"), "json-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("JsonSyncConfig", "jsonsync")
    if (assertTrue("F JSON save 后文件含新值", readFileText("config/sync/json_sync.json").indexOf("json-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("JsonSyncConfig", "jsonsync")
    if (assertEq("F JSON reload 后实例 appName", JsonSyncConfig.ref().get().appName, "json-sync-new")) { pass += 1 } else { fail += 1 }

    // F.2 YAML
    let instFY = YamlSyncConfig.ref().get()
    instFY.appName = "yaml-sync-new"
    instFY.sync()
    if (assertEq("F YAML sync 后注册表 appName", Config.fieldAsString("YamlSyncConfig", "yamlsync", "appName"), "yaml-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("YamlSyncConfig", "yamlsync")
    if (assertTrue("F YAML save 后文件含新值", readFileText("config/sync/yaml_sync.yaml").indexOf("yaml-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("YamlSyncConfig", "yamlsync")
    if (assertEq("F YAML reload 后实例 appName", YamlSyncConfig.ref().get().appName, "yaml-sync-new")) { pass += 1 } else { fail += 1 }

    // F.3 TOML
    let instFT = TomlSyncConfig.ref().get()
    instFT.appName = "toml-sync-new"
    instFT.sync()
    if (assertEq("F TOML sync 后注册表 app.name", Config.fieldAsString("TomlSyncConfig", "tomlsync", "app.name"), "toml-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("TomlSyncConfig", "tomlsync")
    if (assertTrue("F TOML save 后文件含新值", readFileText("config/sync/toml_sync.toml").indexOf("toml-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("TomlSyncConfig", "tomlsync")
    if (assertEq("F TOML reload 后实例 appName", TomlSyncConfig.ref().get().appName, "toml-sync-new")) { pass += 1 } else { fail += 1 }

    // F.4 INI
    let instFI = IniSyncConfig.ref().get()
    instFI.appName = "ini-sync-new"
    instFI.sync()
    if (assertEq("F INI sync 后注册表 app.name", Config.fieldAsString("IniSyncConfig", "inisync", "app.name"), "ini-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("IniSyncConfig", "inisync")
    if (assertTrue("F INI save 后文件含新值", readFileText("config/sync/ini_sync.ini").indexOf("ini-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("IniSyncConfig", "inisync")
    if (assertEq("F INI reload 后实例 appName", IniSyncConfig.ref().get().appName, "ini-sync-new")) { pass += 1 } else { fail += 1 }

    // F.5 XML
    let instFX = XmlSyncConfig.ref().get()
    instFX.appName = "xml-sync-new"
    instFX.sync()
    if (assertEq("F XML sync 后注册表 appName", Config.fieldAsString("XmlSyncConfig", "xmlsync", "appName"), "xml-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("XmlSyncConfig", "xmlsync")
    if (assertTrue("F XML save 后文件含新值", readFileText("config/sync/xml_sync.xml").indexOf("xml-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("XmlSyncConfig", "xmlsync")
    if (assertEq("F XML reload 后实例 appName", XmlSyncConfig.ref().get().appName, "xml-sync-new")) { pass += 1 } else { fail += 1 }

    // F.6 ENV
    let instFE = EnvSyncConfig.ref().get()
    instFE.appName = "env-sync-new"
    instFE.sync()
    if (assertEq("F ENV sync 后注册表 app.name", Config.fieldAsString("EnvSyncConfig", "envsync", "app.name"), "env-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("EnvSyncConfig", "envsync")
    if (assertTrue("F ENV save 后文件含新值", readFileText("config/sync/env_sync.env").indexOf("env-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("EnvSyncConfig", "envsync")
    if (assertEq("F ENV reload 后实例 appName", EnvSyncConfig.ref().get().appName, "env-sync-new")) { pass += 1 } else { fail += 1 }

    // F.7 CONF
    let instFC = ConfSyncConfig.ref().get()
    instFC.appName = "conf-sync-new"
    instFC.sync()
    if (assertEq("F CONF sync 后注册表 app.name", Config.fieldAsString("ConfSyncConfig", "confsync", "app.name"), "conf-sync-new")) { pass += 1 } else { fail += 1 }
    Config.save("ConfSyncConfig", "confsync")
    if (assertTrue("F CONF save 后文件含新值", readFileText("config/sync/conf_sync.conf").indexOf("conf-sync-new").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("ConfSyncConfig", "confsync")
    if (assertEq("F CONF reload 后实例 appName", ConfSyncConfig.ref().get().appName, "conf-sync-new")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // G. 类型保持往返（R8.10）
    // --------------------------------------------------
    section("G. 类型保持往返（R8.10）")
    restoreSyncFile()
    let instG = SyncTestConfig.ref().get()
    instG.enabled = false
    instG.maxRetries = 99
    instG.ratio = 0.75
    instG.sync()
    Config.save("SyncTestConfig", "synctest")
    Config.reload("SyncTestConfig", "synctest")
    let gcfg = SyncTestConfig.ref().get()
    if (assertEq("G enabled 类型保持 = false", gcfg.enabled, false)) { pass += 1 } else { fail += 1 }
    if (assertEq("G maxRetries 类型保持 = 99", gcfg.maxRetries, 99)) { pass += 1 } else { fail += 1 }
    if (assertTrue("G ratio 类型保持 = 0.75", gcfg.ratio > 0.74 && gcfg.ratio < 0.76)) { pass += 1 } else { fail += 1 }
    if (assertEq("G Config.fieldAsBool enabled = false", Config.fieldAsBool("SyncTestConfig", "synctest", "enabled"), false)) { pass += 1 } else { fail += 1 }
    if (assertEq("G Config.fieldAsInt64 maxRetries = 99", Config.fieldAsInt64("SyncTestConfig", "synctest", "maxRetries"), 99)) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // H. @encrypt 字段文件同步往返（R4.4 关联）
    // --------------------------------------------------
    section("H. @encrypt 字段文件同步往返（R4.4 关联）")
    restoreSyncFile()
    let instH = SyncTestConfig.ref().get()
    instH.secret = "new-secret"
    instH.sync()
    Config.save("SyncTestConfig", "synctest")
    let fileH = readFileText("config/sync/sync_test.json")
    if (assertTrue("H 文件含 ENC:v1: 前缀", fileH.indexOf("ENC:v1:").isSome())) { pass += 1 } else { fail += 1 }
    if (assertFalse("H 文件不含明文 new-secret", fileH.indexOf("new-secret").isSome())) { pass += 1 } else { fail += 1 }
    Config.reload("SyncTestConfig", "synctest")
    if (assertEq("H reload 后解密还原 secret", SyncTestConfig.ref().get().secret, "new-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // I. Array<String> 持久化（R8.10 关联）
    // --------------------------------------------------
    section("I. Array<String> 持久化（R8.10 关联）")
    restoreSyncFile()
    let instI = SyncTestConfig.ref().get()
    instI.tags = ["new1", "new2", "new3"]
    instI.sync()
    Config.save("SyncTestConfig", "synctest")
    Config.reload("SyncTestConfig", "synctest")
    let itags = SyncTestConfig.ref().get().tags
    if (assertTrue("I tags size = 3", itags.size == 3)) { pass += 1 } else { fail += 1 }
    if (assertEq("I tags[0] = new1", itags[0], "new1")) { pass += 1 } else { fail += 1 }
    if (assertEq("I tags[2] = new3", itags[2], "new3")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // J. 边界场景（R8.11-R8.15）
    // --------------------------------------------------
    section("J. 边界场景（R8.11-R8.15）")
    restoreSyncFile()

    // J.1 noop sync：不修改直接 sync，数据不变
    let instJ1 = SyncTestConfig.ref().get()
    instJ1.sync()
    if (assertEq("J noop sync 后 app.name 不变", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "sync-test-app")) { pass += 1 } else { fail += 1 }

    // J.2 幂等 sync：连续两次 sync，数据一致
    let instJ2 = SyncTestConfig.ref().get()
    instJ2.sync()
    let v1 = Config.fieldAsString("SyncTestConfig", "synctest", "app.name")
    instJ2.sync()
    let v2 = Config.fieldAsString("SyncTestConfig", "synctest", "app.name")
    if (assertEq("J 幂等 sync 第一次 app.name", v1, "sync-test-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("J 幂等 sync 第二次 app.name 一致", v2, "sync-test-app")) { pass += 1 } else { fail += 1 }

    // J.3 无效 syncField：syncField("nonexistent") 不抛异常
    var j3caught = false
    try {
        let instJ3 = SyncTestConfig.ref().get()
        instJ3.syncField("nonexistent")
    } catch (_: Exception) {
        j3caught = true
    }
    if (assertFalse("J syncField 不存在字段不抛异常", j3caught)) { pass += 1 } else { fail += 1 }

    // J.4 未 sync 被 ref 覆盖：修改 appName 但不 sync，ref().get().appName 为注册表旧值
    let instJ4 = SyncTestConfig.ref().get()
    instJ4.appName = "unsynced-val"
    if (assertEq("J 未 sync 时 ref 覆盖为注册表旧值", SyncTestConfig.ref().get().appName, "sync-test-app")) { pass += 1 } else { fail += 1 }

    // J.5 空字符串持久化：setField → sync → save → reload → getField == ""
    let instJ5 = SyncTestConfig.ref().get()
    instJ5.setField("app.name", "")
    let instJ5s = SyncTestConfig.ref().get()
    instJ5s.sync()
    Config.save("SyncTestConfig", "synctest")
    Config.reload("SyncTestConfig", "synctest")
    if (assertEq("J 空字符串持久化 getField(app.name)", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // K. 外部文件修改 reload（R8.16）
    // --------------------------------------------------
    section("K. 外部文件修改 reload（R8.16）")
    restoreSyncFile()
    let extJson = "{\"app\":{\"name\":\"external-value\",\"version\":\"1.0.0\"},\"server\":{\"port\":\"8080\"},\"enabled\":true,\"maxRetries\":3,\"ratio\":0.5,\"tags\":[\"original\",\"test\"],\"secret\":\"sync-test-secret\"}"
    File.writeTo("config/sync/sync_test.json", extJson.toArray())
    Config.reload("SyncTestConfig", "synctest")
    if (assertEq("K reload 后实例 appName = external-value", SyncTestConfig.ref().get().appName, "external-value")) { pass += 1 } else { fail += 1 }
    if (assertEq("K Config.fieldAsString app.name = external-value", Config.fieldAsString("SyncTestConfig", "synctest", "app.name"), "external-value")) { pass += 1 } else { fail += 1 }

    restoreAllSyncFiles()
    report(pass, fail)
    return (pass, fail)
}
