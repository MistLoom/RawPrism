// 15.1 正确性补充：分段输入一致性（随机分段）、不同并行度并发一致性、
// 扫描与物化前后输入只读不变性。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.random.*
import std.unittest.*
import std.unittest.testmacro.*

// ---------- 分段输入一致性（15.1：随机分段，区域树与一次性输入完全相同） ----------

/// 把字节按随机边界切成多段（每段至少 1 字节）。
internal func randomChunks(data: Array<UInt8>, seed: UInt64): Array<Array<UInt8>> {
    let rng = Random(seed)
    let cuts = ArrayList<Int64>()
    var pos: Int64 = 0
    while (pos < data.size) {
        // 随机段长 1..9，覆盖跨 UTF-8 与跨结构边界的情形
        pos += Int64(rng.nextUInt64() % 9) + 1
        if (pos < data.size) {
            cuts.add(pos)
        }
    }
    let parts = ArrayList<Array<UInt8>>()
    var prev: Int64 = 0
    for (c in cuts) {
        let seg = ArrayList<UInt8>()
        for (i in prev..c) {
            seg.add(data[i])
        }
        parts.add(seg.toArray())
        prev = c
    }
    let tail = ArrayList<UInt8>()
    for (i in prev..data.size) {
        tail.add(data[i])
    }
    if (tail.size > 0) {
        parts.add(tail.toArray())
    }
    parts.toArray()
}

/// 一次性输入与随机分段输入的区域树必须逐项相同。
internal func assertChunkedMatchesWhole(text: String, seeds: Array<UInt64>): Unit {
    let whole = Session(Input(text))
    whole.scan()
    let w = whole.tree.ordered()
    @Assert(w.size >= 1)
    for (seed in seeds) {
        let parts = randomChunks(text.toArray(), seed)
        let inp = Input(StringChunkSource(parts))
        while (inp.hasMore()) {}
        let chunked = Session(inp)
        chunked.scan()
        let c = chunked.tree.ordered()
        @Assert(c.size == w.size)
        for (i in 0..w.size) {
            @Assert(spanEq(w[i].span, c[i].span))
            @Assert(w[i].typeId.text == c[i].typeId.text)
        }
        // 物化结果也一致
        if (w.size > 0) {
            @Assert(whole.getAll([w[0].typeId.text])[0].text() ==
                    chunked.getAll([w[0].typeId.text])[0].text())
        }
    }
}

@Test
func chunkedConsistencyRandomSplitsMixed(): Unit {
    // 混合语料：结构化片段 + URL + email + Markdown 形状
    let text = "log start\n# Title\n\nsee https://u.io/x and mail a@b.io\n" +
               "step {\"id\": 1, \"ok\": true} mid {\"n\": 2}\n" +
               "```json\n{\"k\": [1, 2, 3]}\n```\nend\n"
    assertChunkedMatchesWhole(text, [1, 7, 42, 20260101])
}

@Test
func chunkedConsistencyRandomSplitsCorpora(): Unit {
    assertChunkedMatchesWhole(benchJsonCorpus(20), [3, 99])
    assertChunkedMatchesWhole(benchHtmlCorpus(10), [5, 88])
    assertChunkedMatchesWhole(benchMarkdownCorpus(8), [11, 77])
    assertChunkedMatchesWhole(benchYamlCorpus(10), [13, 55])
}

@Test
func chunkedConsistencyMultibyteBoundaries(): Unit {
    // 分段边界落在 UTF-8 多字节字符内部也必须与一次性输入一致
    let text = "标题中文 {\"键\": \"值\"} 链接 https://中.io/路 尾注 ✅🔒\n"
    assertChunkedMatchesWhole(text, [2, 9, 12345])
}

// ---------- 并发一致性（15.1：不同并行度下区域树相同） ----------

@Test
func concurrentConsistencyAcrossParallelismSweep(): Unit {
    let text = "run\n# Doc\n\n{\"a\": 1} then https://p.io and b@c.io\n" +
               "```json\n{\"q\": 7}\n```\n<!DOCTYPE html><html><body><p>hi</p></body></html>\n"
    let whole = Session(Input(text))
    whole.scan()
    let ref = whole.tree.ordered()

    for (p in [1, 2, 3, 4, 8, 16]) {
        var cfg = ScanConfig()
        cfg.parallelism = p
        let s = Session(Input(text), config: cfg)
        scanConcurrent(s)
        let got = s.tree.ordered()
        @Assert(got.size == ref.size)
        for (i in 0..ref.size) {
            @Assert(spanEq(ref[i].span, got[i].span))
            @Assert(ref[i].typeId.text == got[i].typeId.text)
        }
        // 结果物化一致
        @Assert(s.typeCounts().size == whole.typeCounts().size)
    }
}

// ---------- 只读不变性（15.1：扫描与物化前后输入内容不变） ----------

@Test
func inputReadOnlyAcrossScanAndMaterialize(): Unit {
    let text = "head {\"a\": 1, \"list\": [1, 2]} mid https://r.io/x and m@d.io " +
               "```yaml\nk: v\n```\ntail"
    let input = Input(text)
    let before = input.toBytes()

    let s = Session(input)
    s.scan()
    // 扫描后输入不变
    let afterScan = input.toBytes()
    @Assert(before.size == afterScan.size)
    for (i in 0..before.size) {
        @Assert(before[i] == afterScan[i])
    }

    // 物化（文本与对象视图）后输入仍不变
    for (sel in ["struct.json", "entity.url", "entity.email", "code.block"]) {
        for (rr in s.getAll([sel])) {
            let _ = rr.text()
            let _ = rr.value()
        }
    }
    let afterMat = input.toBytes()
    @Assert(before.size == afterMat.size)
    for (i in 0..before.size) {
        @Assert(before[i] == afterMat[i])
    }
    @Assert(input.toText() == text)
}

@Test
func inputReadOnlyChunkedAcrossScanAndMaterialize(): Unit {
    // 分段输入在扫描与物化过程中同样保持已接收内容不变
    let parts: Array<Array<UInt8>> = [
        "{\"a\": 1} ".toArray(),
        "url https://z.io ".toArray(),
        "mail q@w.io".toArray()
    ]
    let input = Input(StringChunkSource(parts))
    while (input.hasMore()) {}
    let before = input.toBytes()

    let s = Session(input)
    s.scan()
    for (rr in s.getAll(["entity.url"])) {
        let _ = rr.text()
    }
    for (rr in s.getAll(["entity.email"])) {
        let _ = rr.value()
    }
    let after = input.toBytes()
    @Assert(before.size == after.size)
    for (i in 0..before.size) {
        @Assert(before[i] == after[i])
    }
}
