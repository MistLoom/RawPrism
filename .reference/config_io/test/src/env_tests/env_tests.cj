package config_test.env_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.env.*

@config[file = "config/env/env_override.json", id = "envtest"]
class EnvOverrideConfig {
    @key[key = "app.name", env = "TEST_CFG_ENV_OVERRIDE"]
    var appName: String = ""
}

@config[env = true, prefix = "ENV_TEST_", id = "envsource"]
class EnvSourceConfig {
    var appName: String = "default"
    var serverPort: String = "0"
    var timeout: String = "30"
}

public func runEnvTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    section("R11. 环境变量 — 字段级覆盖 + 源模式")

    // A. @key[env=...] 字段级覆盖（R11.1）
    println("\n  [A] @key[env=...] 字段级覆盖")
    setVariable("TEST_CFG_ENV_OVERRIDE", "env-override-val")
    Config.reload("EnvOverrideConfig", "envtest")
    if (assertEq("env 覆盖 appName", Config.fieldAsString("EnvOverrideConfig", "envtest", "app.name"), "env-override-val")) { pass += 1 } else { fail += 1 }

    removeVariable("TEST_CFG_ENV_OVERRIDE")
    Config.reload("EnvOverrideConfig", "envtest")
    if (assertEq("清除 env 后回退文件值", Config.fieldAsString("EnvOverrideConfig", "envtest", "app.name"), "file-override-value")) { pass += 1 } else { fail += 1 }

    // B. @config[env=true] 源模式（R11.2, R11.3）
    println("\n  [B] @config[env=true] 源模式 + prefix 前缀")
    setVariable("ENV_TEST_APP_NAME", "src-app")
    setVariable("ENV_TEST_SERVER_PORT", "4444")
    Config.reload("EnvSourceConfig", "envsource")
    if (assertEq("env 源 appName", Config.fieldAsString("EnvSourceConfig", "envsource", "appName"), "src-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("env 源 serverPort", Config.fieldAsString("EnvSourceConfig", "envsource", "serverPort"), "4444")) { pass += 1 } else { fail += 1 }

    // C. env 源未设置环境变量使用默认值（R11.4）
    println("\n  [C] env 源未设置环境变量使用默认值")
    let envCfg = EnvSourceConfig.ref().get()
    if (assertEq("env 源 timeout 默认值", envCfg.timeout, "30")) { pass += 1 } else { fail += 1 }

    // 清理环境变量
    removeVariable("ENV_TEST_APP_NAME")
    removeVariable("ENV_TEST_SERVER_PORT")

    report(pass, fail)
    return (pass, fail)
}
