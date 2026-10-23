// 15.2 性能与基准：语料生成器、对照基线（每个类型各自完整扫描一遍）、
// @Bench 基准与指标报告测试。
//
// 指标（设计文档 15.2）：
// - 吞吐量（MB/s，RawPrism 单次扫描 vs 基线）
// - 延迟分位数（p50/p95，按输入重复测量）
// - 已标记类型的二次获取耗时（应与结果数量相关、与输入大小无关）
// - 多核加速比（串行 vs parallelism=4）
// 分配次数/峰值内存依赖运行时探测接口，std.unittest 未提供，暂以时间与吞吐为主指标。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.time.*
import std.fs.{File, Path, OpenMode}
import std.unittest.*
import std.unittest.testmacro.*

// ---------- 语料生成器（15.2：HTML、JSON、Markdown、YAML、混合文本 + 对抗样本） ----------

/// JSON 语料：n 条记录。
public func benchJsonCorpus(n: Int64): String {
    let sb = StringBuilder()
    sb.append("{\"users\": [")
    for (i in 0..n) {
        if (i > 0) {
            sb.append(",")
        }
        sb.append("{\"id\": ${i}, \"name\": \"user_${i}\", \"active\": ${i % 2 == 0}, \"score\": ${i}.5}")
    }
    sb.append("]}")
    sb.toString()
}

/// HTML 语料：n 个段落。
public func benchHtmlCorpus(n: Int64): String {
    let sb = StringBuilder()
    sb.append("<!DOCTYPE html><html><head><title>bench</title></head><body>")
    for (i in 0..n) {
        sb.append("<div class=\"row\"><a href=\"https://bench.io/${i}\">item ${i}</a><p>text ${i} body</p></div>")
    }
    sb.append("</body></html>")
    sb.toString()
}

/// Markdown 语料：n 个小节。
public func benchMarkdownCorpus(n: Int64): String {
    let sb = StringBuilder()
    sb.append("# Bench Doc\n\n")
    for (i in 0..n) {
        sb.append("## Section ${i}\n\nPara ${i} with [link](https://md.io/${i}) and note.\n\n```json\n{\"k${i}\": ${i}}\n```\n\n")
    }
    sb.toString()
}

/// YAML 语料：n 个条目。
public func benchYamlCorpus(n: Int64): String {
    let sb = StringBuilder()
    sb.append("---\nconfig:\n")
    for (i in 0..n) {
        sb.append("  item${i}:\n    host: host${i}\n    port: ${8000 + i}\n    tags:\n      - a\n      - b\n")
    }
    sb.append("---\nbody text\n")
    sb.toString()
}

/// 混合文本语料：结构化片段与非结构化文本交织（5.1 其他文本情形）。
public func benchMixedCorpus(n: Int64): String {
    let sb = StringBuilder()
    sb.append("run log start\n")
    for (i in 0..n) {
        sb.append("step ${i}: request {\"id\": ${i}, \"ok\": true} from https://mix.io/${i}\n")
        if (i % 3 == 0) {
            sb.append("contact ops@mix.io for details\n")
        }
    }
    sb.append("run log end\n")
    sb.toString()
}

/// 对抗样本：深度嵌套 JSON。
public func benchAdversarialDeep(): String {
    var s = ""
    for (_ in 0..128) {
        s = s + "["
    }
    s = s + "1"
    for (_ in 0..128) {
        s = s + "]"
    }
    "{\"deep\": ${s}}"
}

/// 对抗样本：超长转义字符串。
public func benchAdversarialLongString(): String {
    var inner = ""
    for (_ in 0..2000) {
        inner = inner + "ab\\n"
    }
    "{\"a\": \"${inner}\"}"
}

/// 对抗样本：非法 UTF-8 字节序列（宽松策略继续扫描）。
public func benchAdversarialInvalidUtf8(): Array<UInt8> {
    var bytes: ArrayList<UInt8> = ArrayList<UInt8>()
    for (b in "log line {\"a\": 1} ".toArray()) {
        bytes.add(b)
    }
    // 孤立续字节 + 截断序列
    bytes.add(0x80)
    bytes.add(0xE4)
    bytes.add(0xBD)
    for (b in " tail https://x.io".toArray()) {
        bytes.add(b)
    }
    bytes.toArray()
}

// ---------- 对照基线（15.2：每个类型各自完整扫描一遍） ----------

/// 基线实现：对每个已注册检测器类型，各自用只含该检测器的会话完整扫描整个输入。
/// 不共享预扫描、不复用类型标记——正是 RawPrism 单次扫描 + 类型标记要超越的形态。
public func baselineEachTypeScan(text: String, parallelism!: Int64 = 1): Int64 {
    let fullReg = defaultRegistry()
    var regionTotal: Int64 = 0
    for (d in fullReg.ordered()) {
        let solo = GetterRegistry()
        let _ = solo.register(d)
        var cfg = ScanConfig()
        cfg.parallelism = parallelism
        let s = Session(Input(text), config: cfg, registry: Some(solo))
        s.scan()
        regionTotal += s.tree.size()
    }
    regionTotal
}

// ---------- @Bench 基准 ----------

const BENCH_MIXED_N: Int64 = 60

/// 混合语料（约数十 KB）。
public func benchMixedInput(): String {
    benchMixedCorpus(BENCH_MIXED_N)
}

@Test
@Bench
public func benchRawPrismScan(): Unit {
    let s = Session(Input(benchMixedInput()))
    s.scan()
}

@Test
@Bench
public func benchBaselineScan(): Unit {
    baselineEachTypeScan(benchMixedInput())
}

@Test
@Bench
public func benchSecondAccess(): Unit {
    // 已标记类型的二次获取（C3 效果：与结果数量相关、与输入大小无关）
    let s = Session(Input(benchMixedInput()))
    s.scan()
    let _ = s.getAll(["entity.url"])
    let _ = s.getAll(["struct.json"])
}

// ---------- 指标报告（15.2） ----------

/// 单次扫描耗时（毫秒）；并行度大于 1 时走并行扫描入口。
internal func measureScanMs(cfg: ScanConfig): Float64 {
    let input = Input(benchMixedInput())
    let s = Session(input, config: cfg)
    let t0 = MonoTime.now()
    if (cfg.parallelism > 1) {
        scanConcurrent(s)
    } else {
        s.scan()
    }
    let t1 = MonoTime.now()
    return Float64((t1 - t0).toMilliseconds())
}

internal func percentile(sorted: ArrayList<Float64>, p: Float64): Float64 {
    if (sorted.size == 0) {
        return 0.0
    }
    let idx = Int64(Float64(sorted.size - 1) * p + 0.5)
    var k = idx
    if (k < 0) {
        k = 0
    }
    if (k >= sorted.size) {
        k = sorted.size - 1
    }
    sorted[k]
}

internal func mbSize(text: String): Float64 {
    Float64(text.size) / (1024.0 * 1024.0)
}

@Test
func benchmarkReport(): Unit {
    // 指标报告写入 target/bench_report.txt（测试框架不透传 stdout）
    let lines = ArrayList<String>()

    // 吞吐量：RawPrism 单次扫描 vs 逐类型独立扫描基线（15.2 对照基线）
    let mixed = benchMixedInput()
    let sizeMb = mbSize(mixed)

    // RawPrism 串行 + 延迟分位数
    var serialTimes: ArrayList<Float64> = ArrayList<Float64>()
    var cfgSerial = ScanConfig()
    cfgSerial.parallelism = 1
    for (_ in 0..8) {
        serialTimes.add(measureScanMs(cfgSerial))
    }
    sortFloats(serialTimes)
    let rpMs = percentile(serialTimes, 0.5)
    let rpThroughput = if (rpMs > 0.0) { sizeMb / (rpMs / 1000.0) } else { 0.0 }

    // 基线（每个类型各自完整扫描一遍）
    let t0 = MonoTime.now()
    let baselineRegions = baselineEachTypeScan(mixed)
    let t1 = MonoTime.now()
    let baseMs = Float64((t1 - t0).toMilliseconds())
    let baseThroughput = if (baseMs > 0.0) { sizeMb / (baseMs / 1000.0) } else { 0.0 }

    lines.add("=== RawPrism 15.2 基准报告 ===")
    lines.add("混合语料大小=${mixed.size} 字节")
    lines.add("RawPrism 扫描 p50=${rpMs} ms 吞吐=${rpThroughput} MB/s")
    lines.add("基线(逐类型独立扫描) 总耗时=${baseMs} ms 吞吐=${baseThroughput} MB/s 区域=${baselineRegions}")
    lines.add("单次扫描/基线 耗时比=${if (baseMs > 0.0) { rpMs / baseMs } else { 0.0 }}")
    lines.add("延迟分位数 p50=${percentile(serialTimes, 0.5)} ms p95=${percentile(serialTimes, 0.95)} ms")

    // 分语料吞吐（15.2：HTML、JSON、Markdown、YAML、混合文本）
    scanCorpusThroughput(lines, "json", benchJsonCorpus(200))
    scanCorpusThroughput(lines, "html", benchHtmlCorpus(200))
    scanCorpusThroughput(lines, "markdown", benchMarkdownCorpus(60))
    scanCorpusThroughput(lines, "yaml", benchYamlCorpus(60))

    // 多核加速比（12 / 15.2）：parallelism=4 vs 串行
    var cfgPar = ScanConfig()
    cfgPar.parallelism = 4
    var parTimes: ArrayList<Float64> = ArrayList<Float64>()
    for (_ in 0..8) {
        parTimes.add(measureScanMs(cfgPar))
    }
    sortFloats(parTimes)
    let parMs = percentile(parTimes, 0.5)
    let speedup = if (parMs > 0.0) { rpMs / parMs } else { 0.0 }
    lines.add("多核加速比 parallelism=4: ${speedup}x (串行 p50=${rpMs} ms, 并行 p50=${parMs} ms)")

    // 二次获取耗时：已标记类型上重复获取（C3 效果）
    let s = Session(Input(mixed))
    s.scan()
    let ta0 = MonoTime.now()
    var n: Int64 = 0
    for (_ in 0..50) {
        n += s.getAll(["entity.url"]).size
        n += s.getAll(["struct.json"]).size
    }
    let ta1 = MonoTime.now()
    let perAccessUs = Float64((ta1 - ta0).toMicroseconds()) / 50.0
    lines.add("二次获取 50 次均值=${perAccessUs} us/次 (url+json 结果数=${n / 50})")

    // 对抗样本（15.1 语料覆盖）：深度嵌套/超长字符串/非法 UTF-8
    let adv0 = MonoTime.now()
    let s1 = Session(Input(benchAdversarialDeep()))
    s1.scan()
    let s2 = Session(Input(benchAdversarialLongString()))
    s2.scan()
    let s3 = Session(Input(benchAdversarialInvalidUtf8()))
    s3.scan()
    let adv1 = MonoTime.now()
    lines.add("对抗样本（深度嵌套/超长字符串/非法 UTF-8）扫描完成，总耗时=${Float64((adv1 - adv0).toMilliseconds())} ms")

    // 写报告文件
    let sb = StringBuilder()
    for (l in lines) {
        sb.append(l)
        sb.append("\n")
    }
    var wrote = false
    try {
        let f = File(Path("target/bench_report.txt"), OpenMode.Write)
        f.write(sb.toString().toArray())
        f.close()
        wrote = true
    } catch (e: Exception) {
        println("[bench] 报告写入失败: ${e}")
    }
    println(sb.toString())
    @Assert(wrote)
}

/// 单类语料的扫描吞吐测量并记录。
internal func scanCorpusThroughput(lines: ArrayList<String>, name: String, corpus: String): Unit {
    let sizeMb = mbSize(corpus)
    let input = Input(corpus)
    let s = Session(input)
    let t0 = MonoTime.now()
    s.scan()
    let t1 = MonoTime.now()
    let ms = Float64((t1 - t0).toMilliseconds())
    let thr = if (ms > 0.0) { sizeMb / (ms / 1000.0) } else { 0.0 }
    lines.add("语料[${name}] 大小=${corpus.size} 字节 耗时=${ms} ms 吞吐=${thr} MB/s 区域=${s.tree.size()}")
}

internal func sortFloats(list: ArrayList<Float64>): Unit {
    for (i in 1..list.size) {
        let key = list[i]
        var j = i - 1
        while (j >= 0 && list[j] > key) {
            list[j + 1] = list[j]
            j -= 1
        }
        list[j + 1] = key
    }
}
