# CHANGELOG

## [0.1.0] - 2026-10-24

## Feature
+ 文本扫描分类：结构化类型（JSON、NDJSON、YAML、TOML、CSV、XML、HTML）、非结构化类型（Markdown、纯文本）、实体（URL、邮箱）
+ Session：只读输入、偏移区间、同类型同区间单次扫描、惰性物化
+ 输入：参数文本、大文件分段、分段迭代器；相同内容下区域树一致
+ 统一 Object 视图与 JSONPath（RFC 9535）
+ 内置检测器与获取器；可注册自定义检测器 / 获取器
+ 并发扫描入口；ScanConfig / ParseLimits 资源上限
+ `@Detector` 属性宏（独立宏包 `rawprism_macros`，主库经路径依赖使用）
+ 单元测试与基准（`cjpm test`；报告 `target/bench_report.txt`）

## Bugfix
+ 无

## Remove
+ 无