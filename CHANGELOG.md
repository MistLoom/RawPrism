# CHANGELOG

## [0.1.2] - 2026-11-03

## Feature
+ `Detector` 接口的 `within` / `dependsOn` / `authoritative` 提供默认实现（空数组）：实现者只需声明 `typeId` 并实现 `detect`，需要时再覆写（已实现这些属性的代码不受影响）

## Bugfix
+ 无

## Remove
+ `@Detector` 属性宏与独立宏包 `rawprism_macros`（`macros/`）：它仅减少检测器声明样板，库自身不使用，现由接口默认实现承担同一职责
+ 主包对 `rawprism_macros` 的中心仓制品依赖：`cjpm.toml` 不再含 `[dependencies]`，主包回到仅依赖仓颉标准库

## [0.1.1] - 2026-11-03

## Feature
+ 主包以中心仓制品形式依赖 `rawprism_macros = "0.1.2"`（不再使用本地路径依赖）

## Bugfix
+ 物化分配以来源实际长度为上界：`Input.fromFile(path).text(超大区间)` 不再按调用方区间预分配而耗尽内存终止进程；负偏移与起止倒置区间报 `IllegalArgumentException`
+ JSONPath `match()` / `search()` 的正则实参限定为字符串字面量（RFC 9535）：被扫描文档中的字段值不再被当作正则编译，文档内容不能决定过滤命中结果
+ CSV 遵守 `ParseLimits.maxStructureLength`：超长行标注 `truncated`，并由 `CsvResult.truncated` 汇总（此前 `limits` 形参被忽略）
+ 制品配置：`bin-dependencies` 指向未使用的 `stdx`，导致消费方未设 `CANGJIE_STDX_PATH` 时 `cjpm build` 失败（仓颉仅依赖标准库，已移除）
+ 制品配置：`include` 未以根目录锚定，按 gitignore 语义误将 `macros/`、`sample/` 内容打入制品
+ 元数据：`tag` 超过中心仓上限 5 个；宏包缺少打包必需的 `README.md` 与 `license`/`authors` 字段
+ 示例 `sample` 无法编译与运行（宏包属性参数 lambda 写法、`Rune` 与字符串字面量比较、示例数据路径）

## Remove
+ 无

## [0.1.0] - 2026-10-24

## Feature
+ 文本扫描分类：结构化类型（JSON、NDJSON、YAML、TOML、CSV、XML、HTML）、非结构化类型（Markdown、纯文本）、实体（URL、邮箱）
+ Session：只读输入、偏移区间、同类型同区间单次扫描、惰性物化
+ 输入：参数文本、大文件分段、分段迭代器；相同内容下区域树一致
+ 统一 Object 视图与 JSONPath（RFC 9535）
+ 内置检测器与获取器；可注册自定义检测器 / 获取器
+ 并发扫描入口；ScanConfig / ParseLimits 资源上限
+ `@Detector` 属性宏（独立宏包 `rawprism_macros`，主库经中心仓制品依赖使用）
+ 单元测试与基准（`cjpm test`；报告 `target/bench_report.txt`）

## Bugfix
+ 无

## Remove
+ 无