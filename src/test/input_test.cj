// 输入测试：三种输入方式一致性（C5）、分段任意边界、保留上限、大文件输入。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.fs.{File, Path, OpenMode, remove}
import std.unittest.*
import std.unittest.testmacro.*

/// 计数分段来源（测试辅助）。
public class CountingSource <: ChunkSource {
    internal let parts: Array<Array<UInt8>>
    internal var idx: Int64
    internal var counter: CounterBox
    public init(parts: Array<Array<UInt8>>, counter: CounterBox) {
        this.parts = parts
        this.idx = 0
        this.counter = counter
    }
    public func next(): ?Array<UInt8> {
        if (idx >= parts.size) {
            return None
        }
        counter.value += 1
        let c = parts[idx]
        idx += 1
        Some(c)
    }
}

/// 失败分段来源（测试辅助，4.4.8）。
public class FailingSource <: ChunkSource {
    internal var idx: Int64
    public init() {
        this.idx = 0
    }
    public func next(): ?Array<UInt8> {
        if (idx == 0) {
            idx = 1
            return Some("ok ".toArray())
        }
        throw Exception("source failure")
    }
}

@Test
func parameterInputBasics(): Unit {
    let input = Input("hello 你好 world")
    @Assert(input.available == "hello 你好 world".size)
    @Assert(input.finished)
    @Assert(input.toText() == "hello 你好 world")
    // 只读：不暴露可写存储（C1），toBytes/toText 是显式副本
    let copy = input.toBytes()
    @Assert(copy.size == input.available)
}

@Test
func textSpanGlobalOffsets(): Unit {
    // C2：区间相对整个输入的偏移
    let text = "aa 你好 bb"
    let input = Input(text)
    // "你好" 起始于字节 3，长度 6
    @Assert(input.text(Span(3, 9)) == "你好")
    @Assert(input.byteAt(0) == Int64(97))
    @Assert(input.byteAt(100) == -1)
}

@Test
func chunkedInputOnDemand(): Unit {
    // 4.4.4：按需拉取，不预先读完迭代器
    let chunks = ["{\"a\":", "1}"]
    let box = CounterBox(0)
    let src = CountingSource([chunks[0].toArray(), chunks[1].toArray()], box)
    let input = Input(src)
    @Assert(!input.finished)
    // 拉取第一段
    @Assert(input.pullNext())
    @Assert(box.value == 1)
    // 再拉取直到结束
    while (input.hasMore()) {}
    @Assert(input.finished)
    @Assert(input.toText() == "{\"a\":1}")
}

@Test
func chunkBoundaryInsideMultibyte(): Unit {
    // 4.4.1：分段边界落在 UTF-8 多字节字符内部
    let text = "a你好b"
    let bytes = text.toArray()
    // 逐字节切段
    var parts: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
    for (b in bytes) {
        parts.add([b])
    }
    let input = Input(StringChunkSource(parts.toArray()))
    while (input.hasMore()) {}
    @Assert(input.toText() == text)
}

@Test
func chunkBoundaryInsideStructure(): Unit {
    // 4.4.2：跨段结构完整识别，结果与一次性输入相同（C5）
    let text = "{\"key\": \"value\", \"n\": [1, 2]}"
    let whole = Session(Input(text))
    whole.scan()
    let wholeJson = whole.getAll(["struct.json"])
    @Assert(wholeJson.size == 1)

    // 分段 1：{"ke   分段 2：y": "val   分段 3：ue", ...
    let parts: Array<String> = ["{\"ke", "y\": \"val", "ue\", \"n\": [1,", " 2]}"]
    var byteParts: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
    for (p in parts) {
        byteParts.add(p.toArray())
    }
    let chunkedInput = Input(StringChunkSource(byteParts.toArray()))
    while (chunkedInput.hasMore()) {}
    let chunked = Session(chunkedInput)
    chunked.scan()
    let chunkedJson = chunked.getAll(["struct.json"])
    @Assert(chunkedJson.size == 1)
    // 区域树相同（C5）
    @Assert(spanEq(wholeJson[0].span, chunkedJson[0].span))
    if (let Some(a) <- chunkedJson[0].value().get("key")) {
        @Assert(a.asText() == Some("value"))
    } else {
        @Assert(false)
    }
}

@Test
func chunkedDeterministicAcrossSplits(): Unit {
    // 随机分段方式输入，区域树与一次性输入完全相同（15.1 分段一致性）
    let text = "head {\"a\": 1} mid https://u.io tail {\"b\": 2} end"
    let whole = Session(Input(text))
    whole.scan()
    let wholeRegions = whole.tree.ordered()
    @Assert(wholeRegions.size >= 3)

    // 逐字节分段
    var byteParts: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
    for (b in text.toArray()) {
        byteParts.add([b])
    }
    let chunkedInput = Input(StringChunkSource(byteParts.toArray()))
    while (chunkedInput.hasMore()) {}
    let chunked = Session(chunkedInput)
    chunked.scan()
    let chunkedRegions = chunked.tree.ordered()
    @Assert(chunkedRegions.size == wholeRegions.size)
    var n: Int64 = wholeRegions.size
    if (chunkedRegions.size < n) {
        n = chunkedRegions.size
    }
    for (i in 0..n) {
        @Assert(spanEq(wholeRegions[i].span, chunkedRegions[i].span))
        @Assert(wholeRegions[i].typeId.text == chunkedRegions[i].typeId.text)
    }
}

@Test
func retentionLimitReportsUnavailable(): Unit {
    // 4.4.6：超出保留上限而无法物化的区域，在获取时明确报告不可用
    let parts: Array<Array<UInt8>> = ["{\"a\": 1}".toArray(), " filler filler filler".toArray()]
    let input = Input(StringChunkSource(parts), retentionLimit: 8)
    while (input.hasMore()) {}
    // 头部字节被丢弃：开头区间不可物化
    @Assert(!input.canMaterialize(Span(0, 3)))
    // 物化被丢弃区间抛出不可用异常（不返回不完整内容）
    var threw = false
    try {
        let _ = input.text(Span(0, 3))
    } catch (e: Exception) {
        threw = true
    }
    @Assert(threw)
}

@Test
func fileInputConsistent(): Unit {
    // 4.3 大文件输入：分段读取，行为与参数输入一致
    let path = "target_test_file.txt"
    let text = "# Doc\n\nBody with https://f.io link.\n"
    // 写文件（测试自备输入）
    let f = File(Path(path), OpenMode.Write)
    f.write(text.toArray())
    f.close()

    let input = Input.fromFile(path, chunkSize: 8)
    while (input.hasMore()) {}
    let s = Session(input)
    s.scan()
    @Assert(s.coarseRootType().text == "text.md")
    @Assert(s.getAll(["entity.url"]).size == 1)

    // 与参数输入一致（C5）
    let s2 = Session(Input(text))
    s2.scan()
    @Assert(s.tree.ordered().size == s2.tree.ordered().size)

    // 可重读来源按区间读取（4.3）
    let fsrc = FileChunkSource(path, chunkSize: 4)
    let bytes = fsrc.readRange(Span(0, 5))
    @Assert(String.fromUtf8(bytes) == "# Doc")
    remove(Path(path))
}

@Test
func strictUtf8PolicyThrows(): Unit {
    // 4.2：非法 UTF-8 严格模式报错
    var bad: Array<UInt8> = [0x61, 0xFF, 0x62]
    var threw = false
    try {
        let _ = Input(bad, policy: UTF8Policy.Strict)
    } catch (e: Exception) {
        threw = true
    }
    @Assert(threw)
}

@Test
func errorRegionPolicyContinues(): Unit {
    // 4.2：宽松模式登记错误区域后继续
    var bad: Array<UInt8> = [0x61, 0xFF, 0x62]
    let input = Input(bad, policy: UTF8Policy.ErrorRegion)
    @Assert(input.invalidUtf8Spans().size == 1)
    @Assert(input.toText().size > 0)
}

@Test
func chunkSourceErrorPropagation(): Unit {
    // 4.4.8：迭代器产生的错误传递给调用方，已产生的结果保持有效
    let input = Input(FailingSource())
    @Assert(input.pullNext())
    var threw = false
    try {
        while (input.hasMore()) {}
    } catch (e: Exception) {
        threw = true
    }
    @Assert(threw)
    // 已产生的结果保持有效
    @Assert(input.text(Span(0, 3)) == "ok ")
}
