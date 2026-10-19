package config_test.error_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ============================================================================
// 错误处理测试类
// ============================================================================

// 包级别错误捕获变量（须在引用它们的 @config 类之前声明）
var _iniErrorCaught: Bool = false
var _confErrorCaught: Bool = false

// 损坏文件：malformed.json 为故意截断的非法 JSON，加载时回退到默认值
@config[file = "config/error/malformed.json", id = "malformed"]
class MalformedConfig {
    @key[key = "app.name"]
    var appName: String = "fallback"
    @key[key = "server.port"]
    var serverPort: String = "0"
}

// 缺失文件：missing.json 在运行时被删除以测试缺失文件回退
@config[file = "config/error/missing.json", id = "missing"]
class MissingConfig {
    @key[key = "app.name"]
    var appName: String = "default-name"
    @key[key = "server.port"]
    var serverPort: String = "0"
}

// 多实例隔离：同文件不同 id
@config[file = "config/error/iso.json", id = "iso-a"]
class IsoConfigA {
    @key[key = "app.name"]
    var appName: String = ""
}

@config[file = "config/error/iso.json", id = "iso-b"]
class IsoConfigB {
    @key[key = "app.name"]
    var appName: String = ""
}

// INI 嵌套拒绝：set Array<String> 触发 @onError
@config[file = "config/error/ini_nested.ini", id = "inierr"]
class IniErrorConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @onError[method = "handleError"]
    var _hook: Int64 = 0

    public func handleError(error: ConfigException): Unit {
        _iniErrorCaught = true
    }
}

// CONF 嵌套拒绝：set Array<String> 触发 @onError
@config[file = "config/error/conf_nested.conf", id = "conferr"]
class ConfErrorConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @onError[method = "handleError"]
    var _hook: Int64 = 0

    public func handleError(error: ConfigException): Unit {
        _confErrorCaught = true
    }
}

// ============================================================================
// 辅助函数
// ============================================================================

private func restoreErrorFiles(): Unit {
    File.writeTo("config/error/missing.json", "{\"app\":{\"name\":\"fallback-missing\"},\"server\":{\"port\":\"9999\"}}".toArray())
    File.writeTo("config/error/iso.json", "{\"app\":{\"name\":\"iso-original\"}}".toArray())
    Config.reload("MissingConfig", "missing")
    Config.reload("IsoConfigA", "iso-a")
    Config.reload("IsoConfigB", "iso-b")
}

// ============================================================================
// 测试节
// ============================================================================

public func runErrorTests(): (Int64, Int64) {
    // 停止文件监听器，避免删除/修改文件时异步重载干扰测试
    Config.stopFileChangeWatcher()

    var pass: Int64 = 0
    var fail: Int64 = 0
    let failures = ArrayList<String>([])

    func record(name: String, ok: Bool): Unit {
        if (ok) {
            pass += 1
        } else {
            fail += 1
            failures.add(name)
        }
    }

    section("error_tests: 错误处理与回退（R13.1 ~ R14.2）")

    // A. 损坏文件回退（R13.1）：MalformedConfig 加载后 appName == "fallback"（默认值），不抛异常
    section("A. 损坏文件回退（R13.1）")
    var noThrowA = true
    var appA = ""
    try {
        let inst = MalformedConfig.ref().get()
        appA = inst.appName
    } catch (_) {
        noThrowA = false
    }
    record(
        "损坏文件不抛异常",
        assertTrue("损坏文件加载不抛异常", noThrowA)
    )
    record(
        "损坏文件回退默认值",
        assertEq("损坏文件回退到默认值 fallback", appA, "fallback")
    )

    // B. 缺失文件回退（R13.2）：删除 missing.json，reload 后优雅回退（不抛异常）
    section("B. 缺失文件回退（R13.2）")
    let initialB = Config.fieldAsString("MissingConfig", "missing", "app.name")
    record(
        "缺失测试初始值来自文件",
        assertEq("缺失测试初始值为 fallback-missing", initialB, "fallback-missing")
    )
    removeIfExists("config/error/missing.json")
    var noThrowB = true
    try {
        Config.reload("MissingConfig", "missing")
    } catch (_) {
        noThrowB = false
    }
    record(
        "缺失文件 reload 不抛异常",
        assertTrue("缺失文件 reload 不抛异常", noThrowB)
    )
    let afterB = Config.fieldAsString("MissingConfig", "missing", "app.name")
    record(
        "缺失文件 reload 后注册表清空",
        assertEq("缺失文件 reload 后注册表无文件值（优雅回退）", afterB, "")
    )

    // C. 多实例隔离（R13.4）：IsoConfigA 和 IsoConfigB 同文件不同 id，A 改后 B 不受影响
    section("C. 多实例隔离（R13.4）")
    Config.enableAutosync("IsoConfigA", "iso-a", false)
    Config.enableAutosync("IsoConfigB", "iso-b", false)
    let aBefore = Config.fieldAsString("IsoConfigA", "iso-a", "app.name")
    let bBefore = Config.fieldAsString("IsoConfigB", "iso-b", "app.name")
    record(
        "多实例初始值 A",
        assertEq("多实例初始值 A 为 iso-original", aBefore, "iso-original")
    )
    record(
        "多实例初始值 B",
        assertEq("多实例初始值 B 为 iso-original", bBefore, "iso-original")
    )
    Config.set("IsoConfigA", "iso-a", "app.name", "modified-by-a")
    let aAfter = Config.fieldAsString("IsoConfigA", "iso-a", "app.name")
    let bAfter = Config.fieldAsString("IsoConfigB", "iso-b", "app.name")
    record(
        "修改后 A 值改变",
        assertEq("修改后 A 值为 modified-by-a", aAfter, "modified-by-a")
    )
    record(
        "修改后 B 值隔离不变",
        assertEq("修改后 B 值仍为 iso-original（隔离）", bAfter, "iso-original")
    )

    // D. INI 嵌套拒绝（R13.3, R14.1）：Config.set 传 Array<String> 触发 @onError
    section("D. INI 嵌套拒绝（R13.3, R14.1）")
    let iniTags: Array<String> = ["a"]
    Config.set("IniErrorConfig", "inierr", "tags", iniTags)
    record(
        "INI 嵌套拒绝触发 onError",
        assertTrue("INI 嵌套拒绝触发 @onError（_iniErrorCaught == true）", _iniErrorCaught)
    )

    // E. CONF 嵌套拒绝（R13.3, R14.2）：Config.set 传 Array<String> 触发 @onError
    section("E. CONF 嵌套拒绝（R13.3, R14.2）")
    let confTags: Array<String> = ["a"]
    Config.set("ConfErrorConfig", "conferr", "tags", confTags)
    record(
        "CONF 嵌套拒绝触发 onError",
        assertTrue("CONF 嵌套拒绝触发 @onError（_confErrorCaught == true）", _confErrorCaught)
    )

    // 恢复配置文件
    restoreErrorFiles()

    report(pass, fail)

    if (fail > 0) {
        println("  失败项:")
        for (name in failures) {
            println("    - ${name}")
        }
    }

    (pass, fail)
}
