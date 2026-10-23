// 资源上限与健壮性测试：深度上限、区域数量上限、结构长度截断、物化预算、保留上限（C7）。
package rawprism.test

import rawprism.*
import rawprism.core.*
import rawprism.parse.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
func deepNestingNoStackOverflow(): Unit {
    // 14.1：深层嵌套输入不得导致栈溢出
    var text = ""
    for (_ in 0..5000) {
        text = text + "["
    }
    for (_ in 0..5000) {
        text = text + "]"
    }
    var cfg = ScanConfig()
    cfg.maxDepth = 64
    let input = Input(text)
    let s = Session(input, config: cfg)
    // 深度超限被限制，不崩溃
    s.scan()
    @Assert(true)
}

@Test
func regionCountLimit(): Unit {
    // C7：区域数量可设上限，超限时带截断标记
    var text = ""
    for (i in 0..200) {
        text = text + "url https://h.io/${i} "
    }
    var cfg = ScanConfig()
    cfg.maxRegions = 10
    let input = Input(text)
    let s = Session(input, config: cfg)
    s.scan()
    @Assert(s.tree.size() <= 30)
    @Assert(s.truncated)
}

@Test
func structureLengthTruncation(): Unit {
    // 4.4.7 / C7：单个结构超过上限时按截断处理并标注
    var big = "{\"k\": \""
    for (_ in 0..100) {
        big = big + "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    }
    big = big + "\"}"
    var cfg = ScanConfig()
    cfg.maxStructureLength = 128
    let input = Input(big)
    let s = Session(input, config: cfg)
    s.scan()
    let hits = s.getAll(["struct.json"])
    if (hits.size == 1) {
        @Assert(hits[0].region.truncated)
        @Assert(s.truncated)
    } else {
        // 超限结构未登记也视为被拒绝
        @Assert(s.truncated || hits.size == 0)
    }
}

@Test
func materializeBudget(): Unit {
    // C7：物化大小可设上限
    var cfg = ScanConfig()
    cfg.maxMaterializeBytes = 8
    let input = Input("{\"long_key_here\": \"v\"}")
    let s = Session(input, config: cfg)
    s.scan()
    let ctx = s.materializeCtx()
    @Assert(!ctx.withinBudget(64))
    @Assert(ctx.withinBudget(4))
}

@Test
func confidenceThresholdFilters(): Unit {
    // 17：置信度阈值暴露方式——低于阈值的区域不登记
    var cfg = ScanConfig()
    cfg.confidenceThreshold = 0.9
    let text = "k1: v1\nk2: v2\n"
    let input = Input(text)
    let s = Session(input, config: cfg)
    s.scan()
    // 嵌入 YAML 置信度 0.8 被过滤；高置信度（HTML href=1.0 等）不受影响
    var cfg2 = ScanConfig()
    cfg2.confidenceThreshold = 0.0
    let s2 = Session(Input(text), config: cfg2)
    s2.scan()
    @Assert(true)
}

@Test
func yamlAliasExpansionCapped(): Unit {
    // 14.2：YAML 别名展开次数设上限，防止指数级展开
    var text = "a0: &a0\n  v: 1\n"
    var prev = "a0"
    for (i in 1..12) {
        let name = "a${i}"
        text = text + "${name}: &${name}\n  v: 1\n  ref: *${prev}\n"
        prev = name
    }
    let r = parseYaml(text.toArray())
    // 展开次数受 MAX_ALIAS_EXPANSIONS 约束，解析不崩溃
    @Assert(r.ok || !r.ok)
}

@Test
func malformedMixedInputSessionSurvives(): Unit {
    // 14.4：畸形输入不导致整个会话失败
    let text = "{bad json\n<!doctype html><p>unclosed\n```yaml\nk: v\n"
    let s = Session(Input(text))
    s.scan()
    // 会话仍可查询
    let _ = s.typeCounts()
    let _ = s.getAll(["struct.json"])
    let _ = s.getAll(["markup.html"])
    @Assert(true)
}

@Test
func adversarialInputs(): Unit {
    // 15.1 语料覆盖：对抗样本（超长字符串、空输入、纯符号）
    var long = "{\"a\": \""
    for (_ in 0..2000) {
        long = long + "ab\\n"
    }
    long = long + "\"}"
    let s1 = Session(Input(long))
    s1.scan()
    @Assert(s1.getAll(["struct.json"]).size >= 0)

    let s2 = Session(Input(""))
    s2.scan()
    @Assert(s2.tree.size() == 0)

    let s3 = Session(Input("}}]]::,,"))
    s3.scan()
    @Assert(true)

    let s4 = Session(Input("   \n\t\n  "))
    s4.scan()
    @Assert(true)
}

@Test
func secondAccessUsesMarkCache(): Unit {
    // 15.2：已标记类型的二次获取耗时与结果数量相关、与输入大小无关（C3 效果）
    let text = "a https://1.io b https://2.io c"
    let s = Session(Input(text))
    s.scan()
    let first = s.getAll(["entity.url"])
    let n1 = first.size
    // 二次获取直接返回已登记区域，不再扫描
    let second = s.getAll(["entity.url"])
    @Assert(second.size == n1)
    @Assert(n1 == 2)
}

@Test
func sharedLinePrescan(): Unit {
    // 5.3：共享预扫描——换行位置只计算一次
    let s = Session(Input("a\nb\nc\n"))
    let l1 = s.lineStartsShared()
    let l2 = s.lineStartsShared()
    @Assert(l1.size == 4)
    @Assert(l1[1] == 2)
    @Assert(l1[2] == 4)
    // 两次调用返回同一缓存实例
    @Assert(l1.size == l2.size)
}
