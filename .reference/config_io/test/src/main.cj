/*
 * config 库多场景测试 — 入口编排器
 *
 * 测试模块（按需求矩阵组织）：
 *   src/format_tests/    格式解析：7 格式基础读取/嵌套/深层嵌套/自动字段识别/全类型
 *   src/encrypt_tests/   加密机制：7 格式透明解密/敏感注册/加密往返/storeField 往返
 *   src/verify_tests/    正则校验：合法值通过/非法值拒绝/validateField/onValidationError
 *   src/listener_tests/  监听器：@onLoaded/@onChange/@onSaved/@onReloaded/@onError/field 过滤
 *   src/crud_tests/      CRUD 操作：全格式增删查改/多深度/批量/混合/空字符串/多实例隔离
 *   src/sync_tests/      同步机制：sync/save/syncField/getField/setField/全格式往返/类型保持/边界
 *   src/merge_tests/     多源合并：priority 优先级叠加/firstExists 模式
 *   src/env_tests/       环境变量：@key[env=...] 字段级覆盖/@config[env=true] 源模式/prefix
 *   src/advanced_tests/  高级 API：basePath/ConfigMap/ConfigRef/fieldAsArrayString/stream
 *   src/error_tests/     错误处理：损坏文件回退/缺失文件回退/INI/CONF 嵌套拒绝/多实例隔离
 *   src/common/          共享断言工具
 */

package config_test

import config_test.format_tests.*
import config_test.encrypt_tests.*
import config_test.verify_tests.*
import config_test.listener_tests.*
import config_test.crud_tests.*
import config_test.sync_tests.*
import config_test.merge_tests.*
import config_test.env_tests.*
import config_test.advanced_tests.*
import config_test.error_tests.*
import config_test.delete_persist_tests.*

main(): Int64 {
    println("========================================")
    println("  config 库多场景测试")
    println("  需求驱动 · 10 模块 · 全格式覆盖")
    println("========================================")

    var totalPass: Int64 = 0
    var totalFail: Int64 = 0

    // R1-R3: 格式解析 + 字段映射 + 类型支持
    let (fp, ff) = runFormatTests()
    totalPass += fp
    totalFail += ff

    // R4: 加密机制
    let (ep, ef) = runEncryptTests()
    totalPass += ep
    totalFail += ef

    // R5: 正则校验
    let (vp, vf) = runVerifyTests()
    totalPass += vp
    totalFail += vf

    // R6: 监听器
    let (lp, lf) = runListenerTests()
    totalPass += lp
    totalFail += lf

    // R7: CRUD 操作
    let (crp, crf) = runCrudTests()
    totalPass += crp
    totalFail += crf

    // R8: 同步机制
    let (sp, sf) = runSyncTests()
    totalPass += sp
    totalFail += sf

    // R9: 多源合并
    let (mp, mf) = runMergeTests()
    totalPass += mp
    totalFail += mf

    // R11: 环境变量
    let (evp, evf) = runEnvTests()
    totalPass += evp
    totalFail += evf

    // R10/R12: 高级 API
    let (adp, adf) = runAdvancedTests()
    totalPass += adp
    totalFail += adf

    // R13/R14: 错误处理与格式限制
    let (erp, erf) = runErrorTests()
    totalPass += erp
    totalFail += erf

    // 删除持久化验证（修复后新增）
    let (dpp, dpf) = runDeletePersistTests()
    totalPass += dpp
    totalFail += dpf

    // 结果汇总
    println("\n========================================")
    println("  总计: ${totalPass} PASS, ${totalFail} FAIL")
    println("========================================")

    if (totalFail == 0) {
        println("\n[全部通过] 所有需求验收标准验证成功!")
    } else {
        println("\n[存在失败] 请检查上方 FAIL 项")
    }

    0
}
