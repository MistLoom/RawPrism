package config_test.merge_tests

import config_io.macros.*
import config_io.*
import config_io.crypto.*
import config_test.common.*
import std.fs.*

@config[file = "config/merge/primary.json", id = "merge"]
class MergeConfig {
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"
    @key[key = "database.host"]
    var databaseHost: String = ""
    @key[key = "database.password"]
    var databasePassword: String = ""
}

@config[file = "config/merge/firstexists_a.json", id = "firstexists"]
class FirstExistsConfig {
    @key[key = "app.name"]
    var appName: String = ""
}

public func runMergeTests(): (Int64, Int64) {
    var pass: Int64 = 0
    var fail: Int64 = 0

    section("R9. 多源合并 — priority 优先级叠加 + firstExists")

    // A. priority 优先级叠加（R9.1, R9.2）
    println("\n  [A] priority 优先级叠加 — secondary 覆盖 primary")
    Config.mergeSources("MergeConfig", "merge", [
        ConfigSource(Format.JSON, "config/merge/secondary.json", "", 1)
    ])
    Config.reload("MergeConfig", "merge")
    if (assertEq("priority appName 覆盖", Config.fieldAsString("MergeConfig", "merge", "app.name"), "secondary-app")) { pass += 1 } else { fail += 1 }
    if (assertEq("priority serverPort 覆盖", Config.fieldAsString("MergeConfig", "merge", "server.port"), "8080")) { pass += 1 } else { fail += 1 }
    if (assertEq("priority databaseHost 覆盖", Config.fieldAsString("MergeConfig", "merge", "database.host"), "secondary-db")) { pass += 1 } else { fail += 1 }
    if (assertEq("priority 独有字段 databasePassword", Config.fieldAsString("MergeConfig", "merge", "database.password"), "secondary-secret")) { pass += 1 } else { fail += 1 }

    // B. firstExists 模式（R9.3）
    println("\n  [B] firstExists — 首个存在文件即停止")
    Config.mergeSources("FirstExistsConfig", "firstexists", [
        ConfigSource(Format.JSON, "config/merge/firstexists_a.json", "", 0, true),
        ConfigSource(Format.JSON, "config/merge/firstexists_b.json", "", 1, false)
    ])
    Config.reload("FirstExistsConfig", "firstexists")
    if (assertEq("firstExists appName 为首个文件值", Config.fieldAsString("FirstExistsConfig", "firstexists", "app.name"), "fe-a-app")) { pass += 1 } else { fail += 1 }
    if (assertFalse("firstExists 不加载 b 文件", Config.fieldAsString("FirstExistsConfig", "firstexists", "app.name") == "fe-b-app")) { pass += 1 } else { fail += 1 }

    report(pass, fail)
    return (pass, fail)
}
