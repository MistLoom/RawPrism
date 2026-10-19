package config_test.verify_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*

// ============================================================
// @config 类：VerifyConfig
//
// 验证两个字段的模式：
//   - server.port：必须为纯数字 ^\d+$
//   - appName：仅允许字母、数字、下划线、连字符 ^[a-zA-Z0-9_\-]+$
//
// @onValidationError 绑定 server.port 字段，验证失败时回调 handleValidationError。
// ============================================================

// 包级别错误捕获变量（须在引用它们的 @config 类之前声明）
var _verifyErrorField: String = ""
var _verifyErrorMsg: String = ""

@config[file = "config/verify/verify.json", id = "verifytest"]
class VerifyConfig {
    @key[key = "server.port"]
    @verify[pattern = "^\\d+$"]
    var serverPort: String = "0"

    @key[key = "appName"]
    @verify[pattern = "^[a-zA-Z0-9_\\-]+$"]
    var appName: String = ""

    @onValidationError[method = "handleValidationError", field = "server.port"]
    var _hook1: Int64 = 0

    public func handleValidationError(field: String, message: String): Unit {
        _verifyErrorField = field
        _verifyErrorMsg = message
    }
}

// ============================================================
// 测试节
// ============================================================

public func runVerifyTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    // --- R5.1 合法值通过 ---
    section("R5.1 合法值通过")

    let initialPort = Config.fieldAsString("VerifyConfig", "verifytest", "server.port")
    if (assertEq("初始server.port为8080", initialPort, "8080")) { pass += 1 } else { fail += 1 }

    VerifyConfig.storeField("server.port", "9999")
    let afterStore = Config.fieldAsString("VerifyConfig", "verifytest", "server.port")
    if (assertEq("storeField合法值9999成功", afterStore, "9999")) { pass += 1 } else { fail += 1 }

    // --- R5.2 非法值拒绝 ---
    section("R5.2 非法值拒绝")

    var r5_2caught = false
    try {
        VerifyConfig.storeField("server.port", "abc")
        // 不应该到这里
    } catch (e: Exception) {
        r5_2caught = true
    }
    if (assertTrue("非法值abc抛异常", r5_2caught)) { pass += 1 } else { fail += 1 }

    // --- R5.3 validateField API ---
    section("R5.3 validateField API")

    // 恢复到合法值
    VerifyConfig.storeField("server.port", "8080")
    let valid1 = Config.validateField("VerifyConfig", "verifytest", "server.port")
    if (assertTrue("validateField初始合法值8080返回true", valid1)) { pass += 1 } else { fail += 1 }

    // 改为另一个合法值后验证
    VerifyConfig.storeField("server.port", "7777")
    let valid2 = Config.validateField("VerifyConfig", "verifytest", "server.port")
    if (assertTrue("validateField改后合法值7777返回true", valid2)) { pass += 1 } else { fail += 1 }

    // --- R5.4 @onValidationError 回调 ---
    section("R5.4 @onValidationError 回调")

    // 重置回调状态
    _verifyErrorField = ""
    _verifyErrorMsg = ""

    try {
        VerifyConfig.storeField("server.port", "not-a-number")
        // 不应该到这里
    } catch (e: Exception) {
        // 预期异常
    }

    if (assertEq("回调字段名为server.port", _verifyErrorField, "server.port")) { pass += 1 } else { fail += 1 }
    if (assertTrue("回调消息非空", _verifyErrorMsg.size > 0)) { pass += 1 } else { fail += 1 }

    // 恢复合法值
    VerifyConfig.storeField("server.port", "8080")

    report(pass, fail)
    (pass, fail)
}
