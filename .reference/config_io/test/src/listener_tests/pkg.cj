package config_test.listener_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*
import std.collection.*

// ============================================================================
// 监听器测试类
// ============================================================================

// 包级别计数器变量（须在引用它们的 @config 类之前声明）
var _loadedCount: Int64 = 0
var _changeField: String = ""
var _changeCount: Int64 = 0
var _savedCount: Int64 = 0
var _reloadedCount: Int64 = 0
var _errorCaught: Bool = false
var _errorCode: String = ""

// 6 类监听器测试类：@onLoaded / @onChange / @onSaved / @onReloaded / @onError
@config[file = "config/listener/listener.json", id = "listener", autosync = false]
class ListenerConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"

    @onLoaded[method = "handleLoaded"]
    var _hook1: Int64 = 0
    @onChange[method = "handleChange", field = "app.name"]
    var _hook2: Int64 = 0
    @onSaved[method = "handleSaved"]
    var _hook3: Int64 = 0

    public func handleLoaded(ref: ConfigRef<Any>): Unit {
        _loadedCount += 1
    }

    public func handleChange(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {
        _changeField = field
        _changeCount += 1
    }

    public func handleSaved(): Unit {
        _savedCount += 1
    }
}

// @onReloaded 测试类
@config[file = "config/listener/reloaded.json", id = "reloaded", autosync = false]
class ReloadedConfig {
    var appName: String = ""
    var serverPort: String = "0"

    @onReloaded[method = "handleReloaded"]
    var _hook1: Int64 = 0

    public func handleReloaded(): Unit {
        _reloadedCount += 1
    }
}

// @onError 测试类 —— INI 不支持嵌套，set Array<String> 会触发 @onError
@config[file = "config/listener/error.ini", id = "errtest"]
class ErrorListenerConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @onError[method = "handleError"]
    var _hook1: Int64 = 0

    public func handleError(error: ConfigException): Unit {
        _errorCaught = true
        _errorCode = error.code
    }
}

// ============================================================================
// 辅助函数
// ============================================================================

private func readFileText(path: String): String {
    if (!exists(path)) {
        return ""
    }
    let data = File.readFrom(path)
    String.fromUtf8(data)
}

private func restoreListenerFile(): Unit {
    File.writeTo("config/listener/listener.json", "{\"app\":{\"name\":\"listener-app\"},\"server\":{\"port\":\"3000\"}}".toArray())
    File.writeTo("config/listener/reloaded.json", "{\"appName\":\"reloaded-app\",\"serverPort\":\"8080\"}".toArray())
    Config.reload("ListenerConfig", "listener")
    Config.reload("ReloadedConfig", "reloaded")
}

// ============================================================================
// 测试节
// ============================================================================

public func runListenerTests(): (Int64, Int64) {
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

    section("listener_tests: 监听器生命周期（R6.1 ~ R6.6）")

    // A. @onLoaded（R6.1）：类加载时触发
    section("A. @onLoaded 类加载触发（R6.1）")
    record(
        "@onLoaded 触发",
        assertTrue("@onLoaded 已触发（_loadedCount > 0）", _loadedCount > 0)
    )

    // B. @onChange（R6.2）：修改 app.name 触发 handleChange
    section("B. @onChange 修改 app.name 触发（R6.2）")
    _changeField = ""
    ListenerConfig.storeField("app.name", "new-val")
    record(
        "@onChange 触发",
        assertTrue("@onChange 已触发（_changeCount > 0）", _changeCount > 0)
    )
    record(
        "@onChange 字段",
        assertEq("@onChange 字段为 app.name", _changeField, "app.name")
    )

    // C. @onSaved（R6.3）：Config.save 后 _savedCount 增加
    section("C. @onSaved 保存触发（R6.3）")
    let savedBefore = _savedCount
    Config.save("ListenerConfig", "listener")
    record(
        "@onSaved 触发",
        assertTrue("@onSaved 已触发（_savedCount 增加）", _savedCount > savedBefore)
    )
    record(
        "保存落盘",
        assertTrue("保存后文件包含 new-val", readFileText("config/listener/listener.json").contains("new-val"))
    )

    // D. @onReloaded（R6.4）：Config.reload 后 _reloadedCount > 0
    section("D. @onReloaded 重载触发（R6.4）")
    Config.reload("ReloadedConfig", "reloaded")
    record(
        "@onReloaded 触发",
        assertTrue("@onReloaded 已触发（_reloadedCount > 0）", _reloadedCount > 0)
    )

    // E. @onError（R6.5）：INI 格式 set Array<String> 触发 @onError
    section("E. @onError INI 嵌套拒绝触发（R6.5）")
    let tags: Array<String> = ["a", "b"]
    Config.set("ErrorListenerConfig", "errtest", "tags", tags)
    record(
        "@onError 触发",
        assertTrue("@onError 已触发（_errorCaught == true）", _errorCaught)
    )
    record(
        "@onError 错误码",
        assertEq("@onError 错误码为 INVALID_NESTED", _errorCode, "INVALID_NESTED")
    )

    // F. @onChange field 过滤（R6.6）：修改 server.port（非 app.name）不触发 handleChange
    section("F. @onChange field 过滤（R6.6）")
    let changeBefore = _changeCount
    let fieldBefore = _changeField
    ListenerConfig.storeField("server.port", "9999")
    record(
        "@onChange 过滤计数不变",
        assertEq("修改 server.port 后 _changeCount 不变", _changeCount, changeBefore)
    )
    record(
        "@onChange 过滤字段不变",
        assertEq("修改 server.port 后 _changeField 仍为 app.name", _changeField, fieldBefore)
    )

    // 恢复配置文件
    restoreListenerFile()

    report(pass, fail)

    if (fail > 0) {
        println("  失败项:")
        for (name in failures) {
            println("    - ${name}")
        }
    }

    (pass, fail)
}
