package config_test.advanced_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.collection.*

@config[file = "config/advanced/basepath.json", id = "basepath", basePath = "app"]
class BasePathConfig {
    @key[key = "name"]
    var appName: String = ""
    @key[key = "version"]
    var appVersion: String = ""
    @key[key = "host"]
    var serverHost: String = ""
    @key[key = "port"]
    var serverPort: String = "0"
}

@config[file = "config/advanced/configmap.json", id = "configmap", autosync = false]
class ConfigMapConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "app.version"]
    var appVersion: String = ""
    @key[key = "server.host"]
    var serverHost: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.host"]
    var databaseHost: String = ""
    @key[key = "database.password"]
    var databasePassword: String = ""
}

@config[file = "config/advanced/ref.json", id = "reftest", autosync = false]
class RefTestConfig {
    var appName: String = ""
    var appVersion: String = ""
    var serverPort: String = "0"
}

@config[file = "config/advanced/generic.json", id = "generic", autosync = false]
class GenericConfig {
    @key[key = "appName"]
    var appName: String = ""
}

@config[file = "config/advanced/stream.json", id = "streamtest", stream = true]
class StreamConfig {
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

public func runAdvancedTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    section("R10/R12. basePath + ConfigMap + ConfigRef + 泛型 + stream")

    // A. basePath 从子对象读取（R10.1）
    println("\n  [A] basePath 从子对象读取")
    let bp = BasePathConfig.ref().get()
    if (assertEq("basePath appName", bp.appName, "bp-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("basePath appVersion", bp.appVersion, "1.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("basePath serverHost", bp.serverHost, "10.0.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("basePath serverPort", bp.serverPort, "4000")) { pass += 1 } else { fail += 1 }

    // B. ConfigMap 链式读取（R12.1）
    println("\n  [B] ConfigMap 链式读取")
    Config.reload("ConfigMapConfig", "configmap")
    let cm = Config.map("ConfigMapConfig", "configmap")
    let cmName = cm["app"]["name"].toDynamicValue()
    match (cmName) {
        case Some(v) =>
            if (assertEq("ConfigMap app.name", v.toString(), "cm-app")) { pass += 1 } else { fail += 1 }
        case None =>
            if (assertFalse("ConfigMap app.name 应有值", true)) { pass += 1 } else { fail += 1 }
    }
    let cmPort = cm["server"]["port"].toDynamicValue()
    match (cmPort) {
        case Some(v) =>
            if (assertEq("ConfigMap server.port", v.toString(), "6000")) { pass += 1 } else { fail += 1 }
        case None =>
            if (assertFalse("ConfigMap server.port 应有值", true)) { pass += 1 } else { fail += 1 }
    }

    // C. ConfigMap 链式写入（R12.2, R12.3）
    println("\n  [C] ConfigMap 链式写入 + 多类型 set")
    cm["app"]["name"].set("cm-new")
    cm["server"]["port"].set(9999)
    if (assertEq("ConfigMap 写入后 app.name", Config.fieldAsString("ConfigMapConfig", "configmap", "app.name"), "cm-new")) { pass += 1 } else { fail += 1 }
    if (assertEq("ConfigMap 写入后 server.port", Config.fieldAsString("ConfigMapConfig", "configmap", "server.port"), "9999")) { pass += 1 } else { fail += 1 }

    // D. ConfigRef 类型安全引用（R12.4, R12.5）
    println("\n  [D] ConfigRef 类型安全引用 + set 方法")
    Config.reload("RefTestConfig", "reftest")
    let ref = RefTestConfig.ref()
    let rcfg = ref.get()
    if (assertEq("ConfigRef 初始 appName", rcfg.appName, "ref-app")) { pass += 1 } else { fail += 1 }
    ref.set("appName", "ref-new")
    if (assertEq("ConfigRef set String", Config.fieldAsString("RefTestConfig", "reftest", "appName"), "ref-new")) { pass += 1 } else { fail += 1 }
    ref.set("serverPort", 8888)
    if (assertEq("ConfigRef set Int64", Config.fieldAsString("RefTestConfig", "reftest", "serverPort"), "8888")) { pass += 1 } else { fail += 1 }

    // E. fieldAsArrayString（R12.6）
    println("\n  [E] fieldAsArrayString 泛型读取数组")
    GenericConfig.storeField("tags", "[\"prod\",\"web\"]")
    let arr = Config.fieldAsArrayString("GenericConfig", "generic", "tags")
    if (assertEq("fieldAsArrayString 长度", Int64(arr.size), 2)) { pass += 1 } else { fail += 1 }
    if (arr.size > 0) {
        let tag0 = arr[0].replace("\"", "")
        if (assertEq("fieldAsArrayString 元素0", tag0, "prod")) { pass += 1 } else { fail += 1 }
    } else {
        if (assertFalse("fieldAsArrayString 应有元素", true)) { pass += 1 } else { fail += 1 }
    }

    // F. fieldAsMapString（R12.7）
    println("\n  [F] fieldAsMapString 泛型读取映射")
    GenericConfig.storeField("metadata", "{\"env\":\"staging\",\"region\":\"us-east\"}")
    let mp = Config.fieldAsMapString("GenericConfig", "generic", "metadata")
    match (mp.get("env")) {
        case Some(v) =>
            if (assertEq("fieldAsMapString env", v.replace("\"", ""), "staging")) { pass += 1 } else { fail += 1 }
        case None =>
            if (assertFalse("fieldAsMapString env 应有值", true)) { pass += 1 } else { fail += 1 }
    }
    match (mp.get("region")) {
        case Some(v) =>
            if (assertEq("fieldAsMapString region", v.replace("\"", ""), "us-east")) { pass += 1 } else { fail += 1 }
        case None =>
            if (assertFalse("fieldAsMapString region 应有值", true)) { pass += 1 } else { fail += 1 }
    }

    // G. stream 流式读取（R12.8）
    println("\n  [G] stream 流式读取配置文件")
    let sc = StreamConfig.ref().get()
    if (assertEq("stream appName", sc.appName, "stream-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("stream appVersion", sc.appVersion, "2.0")) { pass += 1 } else { fail += 1 }
    if (assertEq("stream serverHost", sc.serverHost, "127.0.0.1")) { pass += 1 } else { fail += 1 }
    if (assertEq("stream serverPort", sc.serverPort, "5000")) { pass += 1 } else { fail += 1 }
    if (assertEq("stream databasePassword", sc.databasePassword, "stream-secret")) { pass += 1 } else { fail += 1 }

    report(pass, fail)
    return (pass, fail)
}
