// 输入层：参数输入、分段输入、大文件输入；UTF-8 校验；全局偏移；分段拼接与保留。
package rawprism.core

import std.collection.*
import std.fs.{File, Path, OpenMode, exists}
import std.io.SeekPosition

/// 分段来源：按顺序产出文本分段，分段边界可落在任意位置（含 UTF-8 多字节字符内部）。
/// 迭代器不支持回退（单向性，4.4.9）；结束返回 None。
public interface ChunkSource {
    func next(): ?Array<UInt8>
}

/// 字符串分段来源。
public class StringChunkSource <: ChunkSource {
    internal let chunks: Array<Array<UInt8>>
    internal var index: Int64

    public init(chunks: Array<String>) {
        var arr: ArrayList<Array<UInt8>> = ArrayList<Array<UInt8>>()
        for (c in chunks) {
            arr.add(c.toArray())
        }
        this.chunks = arr.toArray()
        this.index = 0
    }

    public init(bytes: Array<Array<UInt8>>) {
        this.chunks = bytes
        this.index = 0
    }

    public func next(): ?Array<UInt8> {
        if (index >= chunks.size) {
            return None
        }
        let c = chunks[index]
        index += 1
        Some(c)
    }
}

/// 大文件分段来源：按固定字节块顺序读取（4.3，不整体载入内存）。
public class FileChunkSource <: ChunkSource {
    internal let path: String
    internal var handle: Option<File>
    internal let chunkSize: Int64
    internal var done: Bool

    public init(path: String, chunkSize!: Int64 = 65536) {
        this.path = path
        this.chunkSize = chunkSize
        this.handle = None
        this.done = false
    }

    public func next(): ?Array<UInt8> {
        if (done) {
            return None
        }
        if (let None <- handle) {
            if (!exists(Path(path))) {
                done = true
                throw IllegalArgumentException("输入文件不存在: ${path}")
            }
            handle = Some(File(Path(path), OpenMode.Read))
        }
        if (let Some(f) <- handle) {
            let buf = Array<UInt8>(chunkSize, repeat: 0)
            let n = f.read(buf)
            if (n <= 0) {
                f.close()
                done = true
                return None
            }
            return Some(buf[0..n])
        }
        done = true
        None
    }

    /// 可重读来源：按区间重新读取（4.3），供物化使用而不必保留全部内容。
    public func readRange(s: Span): Array<UInt8> {
        let f = File(Path(path), OpenMode.Read)
        try {
            f.seek(SeekPosition.Begin(s.start))
            let buf = Array<UInt8>(s.end - s.start, repeat: 0)
            let n = f.read(buf)
            f.close()
            if (n <= 0) {
                return Array<UInt8>()
            }
            buf[0..n]
        } catch (e: Exception) {
            f.close()
            throw e
        }
    }

    // 总长度未知时以 0 表示，只对已读区间可重读
    internal var totalCache: Int64 = -1

    /// 可重读来源的总长度；用于判断丢弃区间能否按区间重读兜底。
    internal func totalKnown(): Int64 {
        if (totalCache >= 0) {
            return totalCache
        }
        if (!exists(Path(path))) {
            return 0
        }
        let f = File(Path(path), OpenMode.Read)
        try {
            let n = f.seek(SeekPosition.End(0))
            f.close()
            totalCache = n
            return n
        } catch (e: Exception) {
            f.close()
            return 0
        }
    }
}

/// 非法 UTF-8 序列区间（4.2）。
/// 会话按配置处理：严格模式报错（UTF8Policy.Strict），宽松模式登记错误区域后继续（UTF8Policy.ErrorRegion）。
public enum UTF8Policy {
    | Strict
    | ErrorRegion
}

/// 校验 UTF-8，返回全部非法字节区间（有序、不重叠）。
public func validateUtf8(data: Array<UInt8>): ArrayList<Span> {
    let bad = ArrayList<Span>()
    var i: Int64 = 0
    let n: Int64 = data.size
    while (i < n) {
        let b = data[i]
        var len: Int64 = 0
        if (b < 0x80) {
            len = 1
        } else if (b >= 0xC2 && b <= 0xDF) {
            len = 2
        } else if (b >= 0xE0 && b <= 0xEF) {
            len = 3
        } else if (b >= 0xF0 && b <= 0xF4) {
            len = 4
        } else {
            bad.add(Span(i, i + 1))
            i += 1
            continue
        }
        var ok = true
        if (i + len > n) {
            // 截断的多字节序列：整个剩余部分记为一个错误区间
            bad.add(Span(i, n))
            break
        } else {
            var j: Int64 = 1
            while (j < len) {
                let cont = data[i + j]
                if (cont < 0x80 || cont > 0xBF) {
                    ok = false
                    break
                }
                j += 1
            }
        }
        if (ok) {
            // 排除过长编码与代理区
            if (len == 3 && data[i] == 0xE0 && data[i + 1] < 0xA0) {
                ok = false
            } else if (len == 3 && data[i] == 0xED && data[i + 1] > 0x9F) {
                ok = false
            } else if (len == 4 && data[i] == 0xF0 && data[i + 1] < 0x90) {
                ok = false
            } else if (len == 4 && data[i] == 0xF4 && data[i + 1] > 0x8F) {
                ok = false
            }
        }
        if (ok) {
            i += len
        } else {
            bad.add(Span(i, i + 1))
            i += 1
        }
    }
    bad
}

/// 物化不可用异常：分段数据超出保留上限而无法物化时报告（4.4.6），不返回不完整内容。
public class MaterializeUnavailableException <: Exception {
    public let span: Span
    public init(span: Span, message: String) {
        super("区间 [${span.start}, ${span.end}) 物化不可用: ${message}")
        this.span = span
    }
}

/// 会话输入：逻辑上连续的一段文本。
/// 只读约束（C1）：对外不暴露可写的底层存储；需要副本由调用方显式 toBytes/toText。
public class Input {
    /// 已接收的全部字节（分段拼接，全局偏移即此数组下标）。
    internal let data: ArrayList<UInt8>
    /// 保留上限（分段输入 4.4.6）。-1 表示不限制。
    public let retentionLimit: Int64
    /// 因超出保留上限而被丢弃的字节区间（不可再物化）。
    internal let dropped: ArrayList<Span>
    /// 非法 UTF-8 区间。
    internal let invalidUtf8: ArrayList<Span>
    /// 来源（分段输入按需拉取；参数输入为 None，全部字节已在 data 中）。
    internal let source: Option<ChunkSource>
    internal var sourceExhausted: Bool
    /// 可重读来源（大文件输入），物化时允许按区间重读。
    internal let seekable: Option<FileChunkSource>
    /// 输入是否已结束。
    public var finished: Bool

    /// 参数输入：整段文本。
    public init(text: String, policy!: UTF8Policy = UTF8Policy.ErrorRegion) {
        this.data = ArrayList<UInt8>()
        for (b in text.toArray()) {
            data.add(b)
        }
        this.retentionLimit = -1
        this.dropped = ArrayList<Span>()
        this.invalidUtf8 = ArrayList<Span>()
        this.source = None
        this.sourceExhausted = true
        this.seekable = None
        this.finished = true
        recordInvalidUtf8(policy)
    }

    public init(bytes: Array<UInt8>, policy!: UTF8Policy = UTF8Policy.ErrorRegion) {
        this.data = ArrayList<UInt8>()
        for (b in bytes) {
            data.add(b)
        }
        this.retentionLimit = -1
        this.dropped = ArrayList<Span>()
        this.invalidUtf8 = ArrayList<Span>()
        this.source = None
        this.sourceExhausted = true
        this.seekable = None
        this.finished = true
        recordInvalidUtf8(policy)
    }

    /// 分段输入：由迭代器按需产出（4.4.4 按需拉取）。
    public init(source: ChunkSource, retentionLimit!: Int64 = -1, policy!: UTF8Policy = UTF8Policy.ErrorRegion) {
        this.data = ArrayList<UInt8>()
        this.retentionLimit = retentionLimit
        this.dropped = ArrayList<Span>()
        this.invalidUtf8 = ArrayList<Span>()
        this.source = Some(source)
        this.sourceExhausted = false
        this.seekable = None
        this.finished = false
        let _ = policy
    }

    /// 大文件输入：可重读来源（4.3）。用 fromFile 工厂构造以避免与文本构造重载歧义。
    public static func fromFile(path: String, chunkSize!: Int64 = 65536, retentionLimit!: Int64 = -1,
                                policy!: UTF8Policy = UTF8Policy.ErrorRegion): Input {
        let fsrc = FileChunkSource(path, chunkSize: chunkSize)
        return Input(fsrc, fsrc, retentionLimit, policy)
    }

    /// 大文件内部构造：来源与可重读句柄同时挂载。
    internal init(source: ChunkSource, seekableSrc: FileChunkSource,
                  retentionLimit: Int64, policy: UTF8Policy) {
        this.data = ArrayList<UInt8>()
        this.retentionLimit = retentionLimit
        this.dropped = ArrayList<Span>()
        this.invalidUtf8 = ArrayList<Span>()
        this.source = Some(source)
        this.sourceExhausted = false
        this.seekable = Some(seekableSrc)
        this.finished = false
        let _ = policy
    }

    internal func recordInvalidUtf8(policy: UTF8Policy): Unit {
        let bad = validateUtf8(data.toArray())
        invalidUtf8.clear()
        for (s in bad) {
            invalidUtf8.add(s)
        }
        if (isStrictPolicy(policy) && bad.size > 0) {
            let first = bad[0]
            throw IllegalArgumentException("非法 UTF-8 序列位于 [${first.start}, ${first.end})")
        }
    }

    /// 逻辑输入终点（全局偏移，C2：裁剪后仍稳定）。
    public prop available: Int64 {
        get() { baseOffset + data.size }
    }

    /// 是否有更多数据可拉取。
    public func hasMore(): Bool {
        if (finished) {
            return false
        }
        pullNext()
        return !finished
    }

    /// 拉取下一段（若有）。返回是否新增了数据。
    public func pullNext(): Bool {
        if (sourceExhausted) {
            finished = true
            return false
        }
        if (let Some(src) <- source) {
            var next: ?Array<UInt8> = None
            try {
                next = src.next()
            } catch (e: Exception) {
                // 错误传递（4.4.8）：已产生的结果保持有效，输入标记结束
                sourceExhausted = true
                finished = true
                throw e
            }
            if (let None <- next) {
                sourceExhausted = true
                finished = true
                return false
            }
            if (let Some(chunk) <- next) {
                for (b in chunk) {
                    data.add(b)
                }
                // 追加校验新增字节的 UTF-8 合法性（对整段数据重扫末尾 3 字节窗口）
                validateTail(policy_default)
                // 保留上限（4.4.6）
                if (retentionLimit >= 0 && data.size > retentionLimit) {
                    let cut = data.size - retentionLimit
                    // 丢弃头部 cut 字节
                    let fresh = ArrayList<UInt8>()
                    for (i in cut..data.size) {
                        fresh.add(data[i])
                    }
                    data.clear()
                    for (b in fresh) {
                        data.add(b)
                    }
                    dropped.add(Span(baseOffset, baseOffset + cut))
                    // 驻留窗口左端前移 cut；全局偏移保持稳定（C2）
                    baseOffset += cut
                }
                return true
            }
        }
        finished = true
        return false
    }

    internal var baseOffset: Int64 = 0
    internal var policy_default: UTF8Policy = UTF8Policy.ErrorRegion
    internal var lastValidated: Int64 = 0

    /// 追加数据后校验尾部（跨段多字节序列由整段重扫覆盖）。
    internal func validateTail(policy: UTF8Policy): Unit {
        // 多字节字符可能横跨分段边界：对末尾未定界区域整体重扫
        let arr = data.toArray()
        let all = validateUtf8(arr)
        invalidUtf8.clear()
        for (s in all) {
            // 驻留窗口内下标换算为全局偏移（C2）
            invalidUtf8.add(Span(baseOffset + s.start, baseOffset + s.end))
        }
        if (isStrictPolicy(policy) && all.size > 0) {
            let first = all[0]
            throw IllegalArgumentException("非法 UTF-8 序列位于 [${first.start}, ${first.end})")
        }
    }

    /// 到指定全局偏移的数据是否可用（未被丢弃）。
    public func canMaterialize(s: Span): Bool {
        for (d in dropped) {
            if (s.intersects(d)) {
                // 可重读来源兜底
                if (let Some(sk) <- seekable) {
                    if (s.end <= sk.totalKnown()) {
                        continue
                    }
                }
                return false
            }
        }
        true
    }

    /// 取区间文本。偏移为全局偏移；数据被丢弃且不可重读时报告不可用（4.4.6）。
    public func text(s: Span): String {
        if (!canMaterialize(s)) {
            throw MaterializeUnavailableException(s, "分段数据已超出保留上限")
        }
        if (let Some(sk) <- seekable) {
            // 可重读来源按区间重读，不在内存中保留全部内容
            if (s.end > available && !finished) {
                pullUntil(s.end)
            }
            return String.fromUtf8(sk.readRange(s))
        }
        if (s.end > available) {
            if (!finished) {
                pullUntil(s.end)
            }
            if (s.end > available) {
                let clamped = Span(s.start, minI(s.end, available))
                return textFromData(clamped)
            }
        }
        textFromData(s)
    }

    internal func textFromData(s: Span): String {
        // 非法 UTF-8 字节以 U+FFFD 替换，保证物化不失败（4.2 宽松策略）
        // 全局偏移换算为驻留窗口内下标（C2：baseOffset 对齐）
        let lo = maxI(s.start - baseOffset, 0)
        let hi = minI(s.end - baseOffset, data.size)
        let arr = ArrayList<UInt8>()
        for (i in lo..hi) {
            arr.add(data[i])
        }
        if (arr.size == 0) {
            return ""
        }
        let bytes = arr.toArray()
        let bad = validateUtf8(bytes)
        if (bad.size == 0) {
            return String.fromUtf8(bytes)
        }
        let out = ArrayList<UInt8>()
        var cur: Int64 = 0
        for (b in bad) {
            var j = cur
            while (j < b.start) {
                out.add(bytes[j])
                j += 1
            }
            out.add(0xEF)
            out.add(0xBF)
            out.add(0xBD)
            cur = b.end
        }
        var k = cur
        while (k < bytes.size) {
            out.add(bytes[k])
            k += 1
        }
        return String.fromUtf8(out.toArray())
    }

    /// 拉取数据直到全局偏移 reach 可用或输入结束。
    public func pullUntil(reach: Int64): Unit {
        while (!finished && baseOffset + data.size < reach) {
            if (!pullNext()) {
                break
            }
        }
    }

    /// 读取单字节（不越界）。返回 -1 表示不可用。
    public func byteAt(offset: Int64): Int64 {
        let local = offset - baseOffset
        if (local < 0 || local >= data.size) {
            return -1
        }
        Int64(data[local])
    }

    /// 非法 UTF-8 区间只读访问（4.2：宽松模式登记错误区域）。
    public func invalidUtf8Spans(): ArrayList<Span> {
        invalidUtf8
    }

    // ---------- 保留状态报告（4.4.6：超限行为可预期、可报告） ----------

    /// 当前驻留在内存中的字节数（分段输入受保留上限约束）。
    public func retainedBytes(): Int64 {
        data.size
    }

    /// 因超出保留上限而被丢弃、无法再物化的区间（只读副本，4.4.6）。
    public func droppedSpans(): ArrayList<Span> {
        let out = ArrayList<Span>()
        for (s in dropped) {
            out.add(s)
        }
        out
    }

    /// 输入是否仍完整可物化（未发生保留上限丢弃）。
    public func fullyRetained(): Bool {
        dropped.size == 0
    }

    /// 某区间是否可能因保留上限丢弃而不可物化。
    /// 与 canMaterialize 一致；本方法用于在获取前预判并报告原因。
    public func isDropped(s: Span): Bool {
        !canMaterialize(s)
    }

    /// 显式请求独立副本（C1：需要独立副本时由调用方显式请求）。
    public func toBytes(): Array<UInt8> {
        data.toArray()
    }

    public func toText(): String {
        text(Span(0, available))
    }
}

internal func isStrictPolicy(p: UTF8Policy): Bool {
    match (p) {
        case UTF8Policy.Strict => true
        case _ => false
    }
}
