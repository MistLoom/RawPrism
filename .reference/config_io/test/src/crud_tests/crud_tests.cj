/*
 * crud_tests — CRUD 操作测试模块（R7）
 *
 * 覆盖需求：
 *   R7.1-R7.6  全格式 storeField/removeField 增改查删（JSON/YAML/TOML/INI/XML/ENV/CONF）
 *   R7.7       幂等删除（再次 removeField 返回 false）
 *   R7.8       多深度 CRUD（JSON 0/1/2/3 层）
 *   R7.9       批量操作（多字段 storeField + save + reload 保持）
 *   R7.10      混合操作（改 + 增 + 删 + save + reload）
 *   R7.6       storeField 空字符串
 *   R13.4      多实例 CRUD 隔离（同文件不同 id）
 *
 * 测试节：
 *   A. 全格式基础 CRUD — storeField 增改查删（R7.1-R7.6, R7.7）  42 断言
 *   B. 多深度 CRUD — JSON 0/1/2/3 层（R7.8）                    16 断言
 *   C. 批量操作（R7.9）                                          4 断言
 *   D. 混合操作（R7.10）                                         3 断言
 *   E. storeField 空字符串（R7.6）                               7 断言
 *   F. 多实例 CRUD 隔离（R13.4）                                 7 断言
 */

package config_test.crud_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ===== 初始内容常量 =====

private let INIT_JSON = "{\"app\":{\"name\":\"json-crud-app\",\"server\":{\"host\":\"10.0.0.1\",\"port\":\"8080\"}},\"cluster\":{\"node\":{\"config\":{\"timeout\":\"5000\"}}},\"topField\":\"top-default\",\"maxRetries\":3,\"enabled\":true,\"ratio\":0.5,\"tags\":[\"original\"]}"
private let INIT_YAML = "appName: yaml-crud-app\nserverHost: 10.0.0.2\nserverPort: \"9090\"\ntopField: top-default\n"
private let INIT_TOML = "app.name = toml-crud-app\nserver.host = 10.0.0.3\nserver.port = \"7070\"\n"
private let INIT_INI = "# INI CRUD test\n[app]\nname=ini-crud-app\n[server]\nport=6060\n"
private let INIT_XML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<configuration>\n  <entry key=\"appName\">xml-crud-app</entry>\n  <entry key=\"serverPort\">5050</entry>\n</configuration>\n"
private let INIT_ENV = "# ENV CRUD test\napp.name=env-crud-app\nserver.port=4040\n"
private let INIT_CONF = "# CONF CRUD test\napp.name=conf-crud-app\nserver.port=3030\n"

// ===== @config 类（8 个：7 格式 + 1 隔离） =====

@config[file = "config/crud/json_crud.json", id = "jsoncrud", autosync = false]
class JsonCrudConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.server.host"]
    var serverHost: String = ""
    @key[key = "app.server.port"]
    var serverPort: String = "0"
    @key[key = "cluster.node.config.timeout"]
    var deepTimeout: String = "0"
    var topField: String = "default"
    var maxRetries: Int64 = 0
    var enabled: Bool = false
    var ratio: Float64 = 0.0
    var tags: Array<String> = Array<String>()
}

@config[file = "config/crud/yaml_crud.yaml", id = "yamlcrud", autosync = false]
class YamlCrudConfig {
    var appName: String = ""
    var serverHost: String = ""
    var serverPort: String = "0"
    var topField: String = "default"
}

@config[file = "config/crud/toml_crud.toml", id = "tomlcrud", autosync = false]
class TomlCrudConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/crud/ini_crud.ini", id = "inicrud", autosync = false]
class IniCrudConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/crud/xml_crud.xml", id = "xmlcrud", autosync = false]
class XmlCrudConfig {
    var appName: String = ""
    var serverPort: String = "0"
}

@config[file = "config/crud/env_crud.env", id = "envcrud", autosync = false]
class EnvCrudConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/crud/conf_crud.conf", id = "confcrud", autosync = false]
class ConfCrudConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
}

@config[file = "config/crud/json_crud.json", id = "jsoncrud-iso", autosync = false]
class JsonCrudIsoConfig {
    @key[key = "app.name"]
    var appName: String = ""
}

// ===== 辅助函数 =====

private func readFileText(path: String): String {
    if (!exists(path)) {
        return ""
    }
    let data = File.readFrom(path)
    String.fromUtf8(data)
}

private func restoreAllCrudFiles(): Unit {
    File.writeTo("config/crud/json_crud.json", INIT_JSON.toArray())
    File.writeTo("config/crud/yaml_crud.yaml", INIT_YAML.toArray())
    File.writeTo("config/crud/toml_crud.toml", INIT_TOML.toArray())
    File.writeTo("config/crud/ini_crud.ini", INIT_INI.toArray())
    File.writeTo("config/crud/xml_crud.xml", INIT_XML.toArray())
    File.writeTo("config/crud/env_crud.env", INIT_ENV.toArray())
    File.writeTo("config/crud/conf_crud.conf", INIT_CONF.toArray())
    Config.reload("JsonCrudConfig", "jsoncrud")
    Config.reload("YamlCrudConfig", "yamlcrud")
    Config.reload("TomlCrudConfig", "tomlcrud")
    Config.reload("IniCrudConfig", "inicrud")
    Config.reload("XmlCrudConfig", "xmlcrud")
    Config.reload("EnvCrudConfig", "envcrud")
    Config.reload("ConfCrudConfig", "confcrud")
    Config.reload("JsonCrudIsoConfig", "jsoncrud-iso")
}

// 单格式基础 CRUD 流程：查 -> 改 -> 增 -> 删 -> 幂等删，返回 (pass, fail)。
// storeFn/removeFn 传入对应格式 @config 类生成的静态方法，确保走真实生成代码路径。
private func basicCrudFlow(
    label: String,
    typeName: String,
    id: String,
    modifyKey: String,
    initValue: String,
    modifiedValue: String,
    newKey: String,
    newValue: String,
    storeFn: (String, String) -> Unit,
    removeFn: (String) -> Bool
): (Int64, Int64) {
    var p: Int64 = 0
    var f: Int64 = 0
    // 1. 初始值验证（查）
    if (assertEq("${label} 初始值验证(查)", Config.fieldAsString(typeName, id, modifyKey), initValue)) { p += 1 } else { f += 1 }
    // 2. storeField 修改（改）+ 验证
    storeFn(modifyKey, modifiedValue)
    if (assertEq("${label} storeField修改后验证(改)", Config.fieldAsString(typeName, id, modifyKey), modifiedValue)) { p += 1 } else { f += 1 }
    // 3. storeField 新增（增）+ 验证
    storeFn(newKey, newValue)
    if (assertEq("${label} storeField新增后验证(增)", Config.fieldAsString(typeName, id, newKey), newValue)) { p += 1 } else { f += 1 }
    // 4. removeField 删除（返回 true）
    let removed = removeFn(newKey)
    if (assertTrue("${label} removeField删除返回true", removed)) { p += 1 } else { f += 1 }
    // 5. 删后验证（空）
    if (assertEq("${label} 删除后验证为空", Config.fieldAsString(typeName, id, newKey), "")) { p += 1 } else { f += 1 }
    // 6. 幂等删返回 false
    let removedAgain = removeFn(newKey)
    if (assertFalse("${label} 幂等删返回false", removedAgain)) { p += 1 } else { f += 1 }
    (p, f)
}

// ===== 测试入口 =====

public func runCrudTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    // 停止文件监听器，避免写文件时异步重载干扰测试（多次调用幂等安全）。
    Config.stopFileChangeWatcher()
    restoreAllCrudFiles()

    // --------------------------------------------------
    // A. 全格式基础 CRUD — storeField 增改查删（R7.1-R7.6, R7.7）
    // --------------------------------------------------
    section("A. 全格式基础 CRUD — storeField 增改查删（R7.1-R7.6, R7.7）")

    let (jp, jf) = basicCrudFlow("JSON", "JsonCrudConfig", "jsoncrud", "app.name", "json-crud-app", "json-modified", "customNewKey", "json-new-val", { k, v => JsonCrudConfig.storeField(k, v) }, { k => JsonCrudConfig.removeField(k) })
    pass += jp
    fail += jf

    let (yp, yf) = basicCrudFlow("YAML", "YamlCrudConfig", "yamlcrud", "appName", "yaml-crud-app", "yaml-modified", "customNewKey", "yaml-new-val", { k, v => YamlCrudConfig.storeField(k, v) }, { k => YamlCrudConfig.removeField(k) })
    pass += yp
    fail += yf

    let (tp, tf) = basicCrudFlow("TOML", "TomlCrudConfig", "tomlcrud", "app.name", "toml-crud-app", "toml-modified", "custom.new_key", "toml-new-val", { k, v => TomlCrudConfig.storeField(k, v) }, { k => TomlCrudConfig.removeField(k) })
    pass += tp
    fail += tf

    let (ip, ifc) = basicCrudFlow("INI", "IniCrudConfig", "inicrud", "app.name", "ini-crud-app", "ini-modified", "custom.new_key", "ini-new-val", { k, v => IniCrudConfig.storeField(k, v) }, { k => IniCrudConfig.removeField(k) })
    pass += ip
    fail += ifc

    let (xp, xf) = basicCrudFlow("XML", "XmlCrudConfig", "xmlcrud", "appName", "xml-crud-app", "xml-modified", "customNewKey", "xml-new-val", { k, v => XmlCrudConfig.storeField(k, v) }, { k => XmlCrudConfig.removeField(k) })
    pass += xp
    fail += xf

    let (ep, ef) = basicCrudFlow("ENV", "EnvCrudConfig", "envcrud", "app.name", "env-crud-app", "env-modified", "custom.new_key", "env-new-val", { k, v => EnvCrudConfig.storeField(k, v) }, { k => EnvCrudConfig.removeField(k) })
    pass += ep
    fail += ef

    let (cp, cf) = basicCrudFlow("CONF", "ConfCrudConfig", "confcrud", "app.name", "conf-crud-app", "conf-modified", "custom.new_key", "conf-new-val", { k, v => ConfCrudConfig.storeField(k, v) }, { k => ConfCrudConfig.removeField(k) })
    pass += cp
    fail += cf

    // --------------------------------------------------
    // B. 多深度 CRUD — JSON 0/1/2/3 层（R7.8）
    // --------------------------------------------------
    section("B. 多深度 CRUD — JSON 0/1/2/3 层（R7.8）")
    restoreAllCrudFiles()

    // 深度 0: topField（顶层字段）
    if (assertEq("B 深度0 topField读取(查)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "topField"), "top-default")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("topField", "top-0-modified")
    if (assertEq("B 深度0 topField修改验证(改)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "topField"), "top-0-modified")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("depth0New", "depth0-new-val")
    if (assertEq("B 深度0 新增depth0New验证(增)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "depth0New"), "depth0-new-val")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.removeField("depth0New")
    if (assertEq("B 深度0 删除depth0New验证空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "depth0New"), "")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("topField", "top-default") // 恢复原值

    // 深度 1: app.name
    if (assertEq("B 深度1 app.name读取(查)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "json-crud-app")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("app.name", "app-1-modified")
    if (assertEq("B 深度1 app.name修改验证(改)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "app-1-modified")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("newDepth1.field", "depth1-new-val")
    if (assertEq("B 深度1 新增newDepth1.field验证(增)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth1.field"), "depth1-new-val")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.removeField("newDepth1.field")
    if (assertEq("B 深度1 删除newDepth1.field验证空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth1.field"), "")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("app.name", "json-crud-app") // 恢复原值

    // 深度 2: app.server.host
    if (assertEq("B 深度2 app.server.host读取(查)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.server.host"), "10.0.0.1")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("app.server.host", "host-2-modified")
    if (assertEq("B 深度2 app.server.host修改验证(改)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.server.host"), "host-2-modified")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("newDepth2.nested.field", "depth2-new-val")
    if (assertEq("B 深度2 新增newDepth2.nested.field验证(增)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth2.nested.field"), "depth2-new-val")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.removeField("newDepth2.nested.field")
    if (assertEq("B 深度2 删除newDepth2.nested.field验证空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth2.nested.field"), "")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("app.server.host", "10.0.0.1") // 恢复原值

    // 深度 3: cluster.node.config.timeout
    if (assertEq("B 深度3 cluster.node.config.timeout读取(查)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "cluster.node.config.timeout"), "5000")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("cluster.node.config.timeout", "timeout-3-modified")
    if (assertEq("B 深度3 cluster.node.config.timeout修改验证(改)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "cluster.node.config.timeout"), "timeout-3-modified")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("newDepth3.a.b.c", "depth3-new-val")
    if (assertEq("B 深度3 新增newDepth3.a.b.c验证(增)", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth3.a.b.c"), "depth3-new-val")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.removeField("newDepth3.a.b.c")
    if (assertEq("B 深度3 删除newDepth3.a.b.c验证空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "newDepth3.a.b.c"), "")) { pass += 1 } else { fail += 1 }
    JsonCrudConfig.storeField("cluster.node.config.timeout", "5000") // 恢复原值

    // --------------------------------------------------
    // C. 批量操作（R7.9）
    // --------------------------------------------------
    section("C. 批量操作（R7.9）")
    restoreAllCrudFiles()

    JsonCrudConfig.storeField("app.name", "batch-app")
    JsonCrudConfig.storeField("app.server.port", "8888")
    JsonCrudConfig.storeField("topField", "batch-top")
    JsonCrudConfig.storeField("maxRetries", "7")
    Config.save("JsonCrudConfig", "jsoncrud")
    Config.reload("JsonCrudConfig", "jsoncrud")

    if (assertEq("C 批量后app.name保持=batch-app", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "batch-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("C 批量后app.server.port保持=8888", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.server.port"), "8888")) { pass += 1 } else { fail += 1 }
    if (assertEq("C 批量后topField保持=batch-top", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "topField"), "batch-top")) { pass += 1 } else { fail += 1 }
    if (assertEq("C 批量后maxRetries保持=7", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "maxRetries"), "7")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // D. 混合操作（R7.10）
    // --------------------------------------------------
    section("D. 混合操作（R7.10）")
    restoreAllCrudFiles()

    JsonCrudConfig.storeField("app.name", "mix-app")
    JsonCrudConfig.storeField("custom.mix", "mix-val")
    JsonCrudConfig.removeField("topField")
    Config.save("JsonCrudConfig", "jsoncrud")
    Config.reload("JsonCrudConfig", "jsoncrud")

    if (assertEq("D 混合后app.name已改=mix-app", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "mix-app")) { pass += 1 } else { fail += 1 }
    if (assertTrue("D 混合后custom.mix存在且文件已持久化", (Config.fieldAsString("JsonCrudConfig", "jsoncrud", "custom.mix") == "mix-val") && readFileText("config/crud/json_crud.json").contains("mix-val"))) { pass += 1 } else { fail += 1 }
    // 修复后：removeField 持久化到文件，topField 已从文件移除，reload 后不再恢复
    if (assertEq("D 混合后topField已从文件移除=空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "topField"), "")) { pass += 1 } else { fail += 1 }
    if (assertTrue("D topField已从json文件中移除", !readFileText("config/crud/json_crud.json").contains("topField"))) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // E. storeField 空字符串（R7.6）
    // --------------------------------------------------
    section("E. storeField 空字符串（R7.6）")
    restoreAllCrudFiles()

    JsonCrudConfig.storeField("app.name", "")
    if (assertEq("E JSON storeField空字符串", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "")) { pass += 1 } else { fail += 1 }
    YamlCrudConfig.storeField("appName", "")
    if (assertEq("E YAML storeField空字符串", Config.fieldAsString("YamlCrudConfig", "yamlcrud", "appName"), "")) { pass += 1 } else { fail += 1 }
    TomlCrudConfig.storeField("app.name", "")
    if (assertEq("E TOML storeField空字符串", Config.fieldAsString("TomlCrudConfig", "tomlcrud", "app.name"), "")) { pass += 1 } else { fail += 1 }
    IniCrudConfig.storeField("app.name", "")
    if (assertEq("E INI storeField空字符串", Config.fieldAsString("IniCrudConfig", "inicrud", "app.name"), "")) { pass += 1 } else { fail += 1 }
    XmlCrudConfig.storeField("appName", "")
    if (assertEq("E XML storeField空字符串", Config.fieldAsString("XmlCrudConfig", "xmlcrud", "appName"), "")) { pass += 1 } else { fail += 1 }
    EnvCrudConfig.storeField("app.name", "")
    if (assertEq("E ENV storeField空字符串", Config.fieldAsString("EnvCrudConfig", "envcrud", "app.name"), "")) { pass += 1 } else { fail += 1 }
    ConfCrudConfig.storeField("app.name", "")
    if (assertEq("E CONF storeField空字符串", Config.fieldAsString("ConfCrudConfig", "confcrud", "app.name"), "")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // F. 多实例 CRUD 隔离（R13.4）
    // --------------------------------------------------
    section("F. 多实例 CRUD 隔离（R13.4）")
    restoreAllCrudFiles()

    JsonCrudConfig.storeField("app.name", "iso-a-modified")
    if (assertEq("F JsonCrudConfig app.name改为iso-a-modified", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "iso-a-modified")) { pass += 1 } else { fail += 1 }
    if (assertEq("F JsonCrudIsoConfig appName隔离仍为json-crud-app", Config.fieldAsString("JsonCrudIsoConfig", "jsoncrud-iso", "app.name"), "json-crud-app")) { pass += 1 } else { fail += 1 }
    JsonCrudIsoConfig.storeField("app.name", "iso-b-modified")
    if (assertEq("F JsonCrudIsoConfig app.name改为iso-b-modified", Config.fieldAsString("JsonCrudIsoConfig", "jsoncrud-iso", "app.name"), "iso-b-modified")) { pass += 1 } else { fail += 1 }
    if (assertEq("F JsonCrudConfig app.name不受IsoConfig影响仍为iso-a-modified", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "iso-a-modified")) { pass += 1 } else { fail += 1 }
    let removedIso = JsonCrudConfig.removeField("app.name")
    if (assertTrue("F JsonCrudConfig removeField app.name返回true", removedIso)) { pass += 1 } else { fail += 1 }
    if (assertEq("F JsonCrudConfig removeField后app.name为空", Config.fieldAsString("JsonCrudConfig", "jsoncrud", "app.name"), "")) { pass += 1 } else { fail += 1 }
    if (assertEq("F JsonCrudIsoConfig appName不受removeField影响仍为iso-b-modified", Config.fieldAsString("JsonCrudIsoConfig", "jsoncrud-iso", "app.name"), "iso-b-modified")) { pass += 1 } else { fail += 1 }

    restoreAllCrudFiles()
    report(pass, fail)
    (pass, fail)
}
