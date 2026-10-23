# RawPrism

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Cangjie](https://img.shields.io/badge/Language-Cangjie-blue.svg)](https://cangjie-lang.cn/)
[![cjpm](https://img.shields.io/badge/cjpm-rawprism-0.1.0-green.svg)](./cjpm.toml)

纯仓颉文本扫描分类库。读入文本，识别其中的结构化内容、非结构化内容与实体，用相对整段输入的偏移区间标注类型，并按类型取出结果或派生统一对象视图。输入在会话内只读，识别结果均为对输入的区间引用。

定位：多模态 AI 应用中的文本侧基础库——负责文本层的扫描、分类与有界物化；不处理二进制模态，不做语义分析。

一般可用于：多模态检索 / RAG 的文本预处理与分片标注、大数据内容采集后的加工前处理、Agent 工具调用前后的混合载荷拆解、文档或对话流水线中的结构提取与实体定位、评测与数据治理中的格式分类等环节。

---

## 支持的格式与类型

| 类别 | TypeId | 状态 | 说明 |
|------|--------|------|------|
| JSON | `struct.json` | 支持 | 严格解析；可派生 Object |
| NDJSON | `struct.ndjson` | 支持 | 按行 JSON |
| YAML | `struct.yaml` | 支持 | 可派生 Object；别名展开次数有上限 |
| TOML | `struct.toml` | 支持 | 可派生 Object |
| CSV | `struct.csv` | 支持 | 可派生 Object |
| XML | `struct.xml` | 支持 | 带原文偏移；可派生 Object |
| HTML | `markup.html` | 支持 | 容错解析；可含子类型（如 script、style、text、table、meta） |
| Markdown | `text.md` | 支持 | 含标题、段落、代码块、表格、front matter 等 |
| 纯文本 | `text.plain` | 支持 | 非结构内容 |
| URL | `entity.url` | 支持 | 文本中的 URL |
| 邮箱 | `entity.email` | 支持 | 文本中的邮箱 |
| 自定义类型 | 用户声明的 TypeId | 支持 | 通过自定义检测器 / 获取器注册 |
| 二进制输入 | — | 不支持 | 图片、音视频、压缩包、PDF、Office 等不在范围内 |

同一输入可含多种类型。同一会话中，同一类型在同一区间上至多检测一次。

---

## 处理能力

| 能力 | 状态 | 说明 |
|------|------|------|
| 只读输入 | 支持 | 不修改输入；不对外暴露可写输入存储 |
| 区间 `[start, end)` | 支持 | 相对整段输入起点；嵌套与分段输入相同 |
| 参数输入 | 支持 | 一次传入整段文本 |
| 大文件输入 | 支持 | 按路径或可读流分段读取 |
| 分段输入 | 支持 | 由调用方按序提供文本分段 |
| 输入方式一致性 | 支持 | 相同文本内容下，区域树与输入方式无关 |
| 惰性物化 | 支持 | 区域仅在被请求时物化；结果可缓存 |
| 统一 Object 视图 | 支持 | 来源包括 JSON、YAML、XML/HTML、CSV、TOML、front matter |
| JSONPath（RFC 9535） | 支持 | 在 Object 上查询 |
| 自定义检测器 / 获取器 | 支持 | 实现 `Detector` / `Getter<T>` 并注册到 `GetterRegistry` |
| `@Detector` 属性宏 | 支持 | 独立宏包 `rawprism_macros`（`macros/`）；用于减少检测器声明样板 |
| 检测依赖与副产物登记 | 支持 | 可声明 `dependsOn`；扫描中观察到的其它类型须登记供复用 |
| 并发扫描 | 支持 | 见 `scanAsync`、`scanConcurrent` 等 |
| 资源上限 | 支持 | 深度、区域数量、物化大小等由 `ScanConfig` / `ParseLimits` 配置；超限返回带截断标记的部分结果 |
| 内容格式转换 | 不支持 | 例如 HTML 转 Markdown 非内置能力；可由调用方自行注册转换 |
| 语义分析 | 不支持 | 例如情感分析、实体消歧 |
| 网络获取 | 不支持 | 不发起网络请求；文件读取仅用于大文件输入 |

---

## 环境

- 仓颉 SDK 1.2.0（与 `cjpm.toml` 中 `cjc-version` 一致）
- `cjpm` 构建与测试

若使用 `stdx` 静态库，需设置 `CANGJIE_STDX_PATH`（见 `cjpm.toml` 中 `bin-dependencies`）。

---

## 安装

```toml
[dependencies]
rawprism = { git = "https://github.com/MistLoom/RawPrism.git", tag = "v0.1.0" }
```

本地路径：

```toml
[dependencies]
rawprism = { path = "../RawPrism", output-type = "static" }
```

```bash
cjpm build
```

---

## 使用

```cangjie
import rawprism.*
import rawprism.core.*

main() {
    let text =
        "# note\n" +
        "{ \"name\": \"RawPrism\", \"tags\": [\"cangjie\", \"scan\"] }\n" +
        "https://example.com/docs\n"
    let session = Session(Input(text))
    session.scan()

    let docs = session.getAll(["struct.json"])
    for (got in docs) {
        let obj = got.value()
        if (let Some(name) <- obj.get("name")) {
            println(name.asString())
        }
    }

    let urls = session.getAll(["entity.url"])
    println(urls.size)
}
```

Object 上的 JSONPath：

```cangjie
import rawprism.object.*

let hits = jsonPath(root, "$..tags[*]")
```

自定义类型：实现 `Detector` / `Getter<T>`（可声明 `typeId`、`dependsOn` 等），注册到 `GetterRegistry`。可选使用 `@Detector` 宏。

---

## 构建与测试

```bash
cjpm build
cjpm test
```

基准随 `cjpm test` 运行，报告写入 `target/bench_report.txt`。

---

## 目录

```text
RawPrism/
├── cjpm.toml
├── LICENSE
├── CHANGELOG.md
├── README.md
├── macros/               # 独立宏包 rawprism_macros（@Detector）
│   ├── cjpm.toml
│   └── src/
└── src/
    ├── builtin.cj
    ├── concurrent.cj
    ├── detector.cj
    ├── session.cj
    ├── core/
    ├── object/
    ├── parse/
    └── test/
```

---

## 版本

当前版本 0.1.0。变更见 [CHANGELOG.md](./CHANGELOG.md)。

## 许可证

[MIT License](./LICENSE)