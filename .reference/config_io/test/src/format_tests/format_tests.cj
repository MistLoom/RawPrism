/*
 * format_tests — 格式解析与字段映射测试模块
 *
 * 覆盖需求：
 *   R1（格式解析）：JSON 嵌套/深层嵌套、YAML 扁平键、TOML 点路径、INI [section]、
 *                   XML entry、ENV KEY=VALUE、CONF 扁平键
 *   R2（字段映射）：@key 点路径映射、自动字段识别、id 缺省（default）
 *
 * 测试节：
 *   A. JSON 嵌套对象解析（R1.1）
 *   B. JSON 深层嵌套 3 层（R1.2）
 *   C. JSON 自动字段识别 + 全类型（R2.2, R3.1-R3.6）
 *   D. YAML 扁平键（R1.3）
 *   E. TOML 点路径分段（R1.5, R1.6）
 *   F. INI [section] 分段（R1.7, R1.8）
 *   G. XML 扁平 entry（R1.9）
 *   H. ENV KEY=VALUE（R1.11, R1.12）
 *   I. CONF 扁平键（R1.13, R1.14）
 *   J. id 缺省（R2.4）
 */

package config_test.format_tests

import std.collection.*
import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*

// ===== @config 类定义 =====

// JSON — 嵌套 + 深层嵌套 + 全类型 + 自动字段识别
@config[file = "config/format/json_fmt.json", id = "jsonfmt"]
class JsonFmtConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.password"]
    var databasePassword: String = ""
    @key[key = "cluster.node.config.timeout"]
    var deepTimeout: String = "0"
    var topField: String = ""
    var enabled: Bool = false
    var maxRetries: Int64 = 0
    var ratio: Float64 = 0.0
    var tags: Array<String> = Array<String>()
    var metadata: HashMap<String, String> = HashMap<String, String>()
}

// YAML — 扁平键自动字段识别
@config[file = "config/format/yaml_fmt.yaml", id = "yamlfmt"]
class YamlFmtConfig {
    var appName: String = ""
    var serverPort: String = "0"
    var debug: Bool = false
    var password: String = ""
}

// TOML — 点路径键
@config[file = "config/format/toml_fmt.toml", id = "tomlfmt"]
class TomlFmtConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.password"]
    var databasePassword: String = ""
}

// INI — [section] 分段
@config[file = "config/format/ini_fmt.ini", id = "inifmt"]
class IniFmtConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.password"]
    var databasePassword: String = ""
}

// XML — 扁平 entry 自动字段识别
@config[file = "config/format/xml_fmt.xml", id = "xmlfmt"]
class XmlFmtConfig {
    var appName: String = ""
    var serverPort: String = "0"
    var password: String = ""
}

// ENV — 扁平点路径
@config[file = "config/format/env_fmt.env", id = "envfmt"]
class EnvFmtConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.password"]
    var databasePassword: String = ""
}

// CONF — 扁平点路径
@config[file = "config/format/conf_fmt.conf", id = "conffmt"]
class ConfFmtConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.password"]
    var databasePassword: String = ""
}

// id 缺省测试
@config[file = "config/format/default_id.json"]
class DefaultIdConfig {
    @key[key = "app.name"]
    var appName: String = ""
}

// ===== 测试函数 =====

public func runFormatTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    // --------------------------------------------------
    // A. JSON 嵌套对象解析（R1.1）
    //    验证 5 个嵌套字段：app.name / app.version / server.host / server.port / database.password
    // --------------------------------------------------
    section("A. JSON 嵌套对象解析（R1.1）")
    let jcfg = JsonFmtConfig.ref().get()
    if (assertEq("JSON appName (app.name 嵌套)", jcfg.appName, "json-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON appVersion (app.version 嵌套)", jcfg.appVersion, "2.1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON serverHost (server.host 嵌套)", jcfg.serverHost, "127.0.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON serverPort (server.port 嵌套)", jcfg.serverPort, "3000")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON databasePassword (database.password 嵌套)", jcfg.databasePassword, "json-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // B. JSON 深层嵌套 3 层（R1.2）
    //    验证 cluster.node.config.timeout = "5000"
    // --------------------------------------------------
    section("B. JSON 深层嵌套 3 层（R1.2）")
    if (assertEq("JSON deepTimeout (cluster.node.config.timeout 深层3层)", jcfg.deepTimeout, "5000")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // C. JSON 自动字段识别 + 全类型（R2.2, R3.1-R3.6）
    //    验证 topField(String) / enabled(Bool) / maxRetries(Int64) /
    //         ratio(Float64) / tags(Array<String>) / metadata(HashMap<String,String>)
    // --------------------------------------------------
    section("C. JSON 自动字段识别 + 全类型（R2.2, R3.1-R3.6）")
    if (assertEq("JSON topField (String 自动识别)", jcfg.topField, "top-val")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON enabled (Bool 自动识别)", jcfg.enabled, true)) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON maxRetries (Int64 自动识别)", jcfg.maxRetries, 3)) { pass += 1 } else { fail += 1 }
    if (assertTrue("JSON ratio (Float64 自动识别) = 0.5", jcfg.ratio == 0.5)) { pass += 1 } else { fail += 1 }
    if (assertTrue("JSON tags (Array<String>) size = 3", jcfg.tags.size == 3)) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON tags[0] = a", jcfg.tags[0], "a")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON tags[1] = b", jcfg.tags[1], "b")) { pass += 1 } else { fail += 1 }
    if (assertEq("JSON tags[2] = c", jcfg.tags[2], "c")) { pass += 1 } else { fail += 1 }
    if (assertTrue("JSON metadata (HashMap<String,String>) size = 2", jcfg.metadata.size == 2)) { pass += 1 } else { fail += 1 }
    let metaEnv = match (jcfg.metadata.get("env")) {
        case Some(v) => v
        case None => "<missing>"
    }
    if (assertEq("JSON metadata[env] = prod", metaEnv, "prod")) { pass += 1 } else { fail += 1 }
    let metaRegion = match (jcfg.metadata.get("region")) {
        case Some(v) => v
        case None => "<missing>"
    }
    if (assertEq("JSON metadata[region] = us-east", metaRegion, "us-east")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // D. YAML 扁平键（R1.3）
    //    验证 appName / serverPort / debug / password（自动字段识别）
    // --------------------------------------------------
    section("D. YAML 扁平键（R1.3）")
    let ycfg = YamlFmtConfig.ref().get()
    if (assertEq("YAML appName (扁平键自动识别)", ycfg.appName, "yaml-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("YAML serverPort (扁平键引号值)", ycfg.serverPort, "4000")) { pass += 1 } else { fail += 1 }
    if (assertEq("YAML debug (Bool 扁平键)", ycfg.debug, true)) { pass += 1 } else { fail += 1 }
    if (assertEq("YAML password (扁平键引号值)", ycfg.password, "yaml-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // E. TOML 点路径分段（R1.5, R1.6）
    //    验证 5 个字段：app.name / app.version / server.host / server.port / database.password
    // --------------------------------------------------
    section("E. TOML 点路径分段（R1.5, R1.6）")
    let tcfg = TomlFmtConfig.ref().get()
    if (assertEq("TOML appName (app.name 点路径)", tcfg.appName, "toml-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("TOML appVersion (app.version 引号值)", tcfg.appVersion, "2.1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("TOML serverHost (server.host 无引号IP)", tcfg.serverHost, "10.0.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("TOML serverPort (server.port 引号值)", tcfg.serverPort, "5000")) { pass += 1 } else { fail += 1 }
    if (assertEq("TOML databasePassword (database.password 引号值)", tcfg.databasePassword, "toml-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // F. INI [section] 分段（R1.7, R1.8）
    //    验证 5 个字段：app.name / app.version / server.host / server.port / database.password
    // --------------------------------------------------
    section("F. INI [section] 分段（R1.7, R1.8）")
    let icfg = IniFmtConfig.ref().get()
    if (assertEq("INI appName ([app] name)", icfg.appName, "ini-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("INI appVersion ([app] version)", icfg.appVersion, "2.1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("INI serverHost ([server] host)", icfg.serverHost, "172.16.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("INI serverPort ([server] port)", icfg.serverPort, "6000")) { pass += 1 } else { fail += 1 }
    if (assertEq("INI databasePassword ([database] password)", icfg.databasePassword, "ini-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // G. XML 扁平 entry（R1.9）
    //    验证 appName / serverPort / password（自动字段识别）
    // --------------------------------------------------
    section("G. XML 扁平 entry（R1.9）")
    let xcfg = XmlFmtConfig.ref().get()
    if (assertEq("XML appName (entry key=appName)", xcfg.appName, "xml-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("XML serverPort (entry key=serverPort)", xcfg.serverPort, "7000")) { pass += 1 } else { fail += 1 }
    if (assertEq("XML password (entry key=password)", xcfg.password, "xml-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // H. ENV KEY=VALUE（R1.11, R1.12）
    //    验证 5 个字段：app.name / app.version / server.host / server.port / database.password
    // --------------------------------------------------
    section("H. ENV KEY=VALUE（R1.11, R1.12）")
    let ecfg = EnvFmtConfig.ref().get()
    if (assertEq("ENV appName (app.name)", ecfg.appName, "env-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("ENV appVersion (app.version)", ecfg.appVersion, "2.1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("ENV serverHost (server.host)", ecfg.serverHost, "100.64.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("ENV serverPort (server.port)", ecfg.serverPort, "8000")) { pass += 1 } else { fail += 1 }
    if (assertEq("ENV databasePassword (database.password)", ecfg.databasePassword, "env-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // I. CONF 扁平键（R1.13, R1.14）
    //    验证 5 个字段：app.name / app.version / server.host / server.port / database.password
    // --------------------------------------------------
    section("I. CONF 扁平键（R1.13, R1.14）")
    let ccfg = ConfFmtConfig.ref().get()
    if (assertEq("CONF appName (app.name)", ccfg.appName, "conf-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("CONF appVersion (app.version)", ccfg.appVersion, "2.1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("CONF serverHost (server.host)", ccfg.serverHost, "198.51.100.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("CONF serverPort (server.port)", ccfg.serverPort, "9000")) { pass += 1 } else { fail += 1 }
    if (assertEq("CONF databasePassword (database.password)", ccfg.databasePassword, "conf-secret")) { pass += 1 } else { fail += 1 }

    // --------------------------------------------------
    // J. id 缺省（R2.4）
    //    验证 DefaultIdConfig 不指定 id 时使用 "default"
    // --------------------------------------------------
    section("J. id 缺省（R2.4）")
    let dcfg = DefaultIdConfig.ref().get()
    if (assertEq("DefaultId appName (id 缺省实例字段)", dcfg.appName, "default-id-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("DefaultId Config.fieldAsString(id=default)", Config.fieldAsString("DefaultIdConfig", "default", "app.name"), "default-id-app")) { pass += 1 } else { fail += 1 }

    report(pass, fail)
    (pass, fail)
}
