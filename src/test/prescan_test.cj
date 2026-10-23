// 17 待定项：共享预扫描机制、实体匹配对不可信输入有界。
package rawprism.test

import rawprism.*
import rawprism.core.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/// 计数盒（bump 返回自增值，供闭包单表达式使用）。
public class BumpBox {
    public var value: Int64
    public init(v: Int64) {
        this.value = v
    }
    public func bump(): Int64 {
        this.value += 1
        this.value
    }
}

/// 共享预扫描使用方（测试辅助）：验证同一 key 只计算一次。
public class PrescanUserDetector <: Detector {
    internal let counter: BumpBox
    public init(counter: BumpBox) {
        this.counter = counter
    }
    public prop typeId: TypeId { get() { TypeId("x.prescanuser") } }
    public prop within: Array<String> { get() { [] } }
    public prop dependsOn: Array<TypeId> { get() { [] } }
    public prop authoritative: Array<TypeId> { get() { [] } }
    public func detect(scope: Span, ctx: DetectContext): Unit {
        let _ = scope
        let holder = (ctx.session as Session).getOrThrow()
        let box = this.counter
        // 两次请求同一 key：第二次必须命中缓存，不再计算
        let _ = holder.prescan<Int64>("test.counter", { => box.bump() })
        let _ = holder.prescan<Int64>("test.counter", { => box.bump() })
    }
}

@Test
func sharedPrescanComputedOnce(): Unit {
    // 5.3 / 17：同一 key 的共享预扫描在一个会话内只计算一次
    let counter = BumpBox(0)
    let reg = GetterRegistry()
    @Assert(reg.register(PrescanUserDetector(counter)))
    let s = Session(Input("plain text"), registry: Some(reg))
    s.scan()
    @Assert(counter.value == 1)
    // 直接调用同样命中缓存
    let _ = s.prescan<Int64>("test.counter", { => counter.bump() })
    @Assert(counter.value == 1)
    // 不同 key 独立计算
    let _ = s.prescan<Int64>("test.other", { => counter.bump() })
    @Assert(counter.value == 2)
}

@Test
func entityMatchBoundedOnUntrustedInput(): Unit {
    // 17：匹配时间对不可信输入有界——超长 token 不命中，扫描仍完成
    // 10 KB 连续无空白字符（远超默认 maxEntityLength=2048）
    var long = ""
    for (_ in 0..10000) {
        long = long + "a"
    }
    let text = "head https://${long}/tail end a@${long}.io x"
    let s = Session(Input(text))
    s.scan()
    @Assert(s.getAll(["entity.url"]).size == 0)
    @Assert(s.getAll(["entity.email"]).size == 0)
    @Assert(!s.truncated)

    // 可用上限收紧：正常 URL 在更小上限下也不命中
    var cfg = ScanConfig()
    cfg.maxEntityLength = 8
    let s2 = Session(Input("see https://example.com/x here"), config: cfg)
    s2.scan()
    @Assert(s2.getAll(["entity.url"]).size == 0)
}

@Test
func entityMatchBoundKeepsNormalMatches(): Unit {
    // 有界匹配不影响常规实体：边界内正常命中
    let text = "visit https://ok.io/path?q=1 and mail u@d.io now"
    let s = Session(Input(text))
    s.scan()
    let urls = s.getAll(["entity.url"])
    let mails = s.getAll(["entity.email"])
    @Assert(urls.size == 1)
    @Assert(mails.size == 1)
    @Assert(urls[0].text() == "https://ok.io/path?q=1")
    @Assert(mails[0].text() == "u@d.io")
}
