// 扫描配置：资源上限（C7）、并发度、时间预算、错误策略。
package rawprism.core

/// 解析配置：深度上限（14.1）、结构最大长度（4.4.7）、截断标记。
public class ParseLimits {
    public let maxDepth: Int64
    public let maxStructureLength: Int64
    /// 深度超限是否截断（true 截断并标注 truncated；false 失败）。
    public let truncateOnDepth: Bool

    public init(maxDepth!: Int64 = 256, maxStructureLength!: Int64 = 16 * 1024 * 1024,
                truncateOnDepth!: Bool = true) {
        this.maxDepth = maxDepth
        this.maxStructureLength = maxStructureLength
        this.truncateOnDepth = truncateOnDepth
    }
}

/// 扫描配置。
public class ScanConfig {
    /// 嵌套深度上限（14.1）。
    public var maxDepth: Int64 = 256
    /// 单个结构最大长度（4.4.7）。超过按 C7 截断并标注。
    public var maxStructureLength: Int64 = 16 * 1024 * 1024
    /// 区域数量上限。超限时停止新增区域并带截断标记。
    public var maxRegions: Int64 = 100000
    /// 物化大小上限（单次物化的最大字节数）。
    public var maxMaterializeBytes: Int64 = 64 * 1024 * 1024
    /// 并行度上限（12.4）。1 表示串行。
    public var parallelism: Int64 = 1
    /// 时间预算（毫秒）。0 表示不限。超时返回已有结果并带截断标记（12.7）。
    public var timeBudgetMs: Int64 = 0
    /// 非法 UTF-8 处理策略（4.2）。
    public var utf8Policy: UTF8Policy = UTF8Policy.ErrorRegion
    /// 深度超限时截断而非失败。
    public var truncateOnDepth: Bool = true
    /// 置信度阈值：低于该值的区域不登记（17：阈值暴露方式）。
    public var confidenceThreshold: Float64 = 0.0
    /// 实体匹配长度上限（17：匹配时间对不可信输入有界）。
    /// 单个 URL / Email 的匹配尝试超过该字节数即放弃（不命中），继续向后扫描。
    public var maxEntityLength: Int64 = 2048

    public init() {}
}

/// 内部解析限制视图。
public func limitsOf(cfg: ScanConfig): ParseLimits {
    ParseLimits(maxDepth: cfg.maxDepth, maxStructureLength: cfg.maxStructureLength,
        truncateOnDepth: cfg.truncateOnDepth)
}
