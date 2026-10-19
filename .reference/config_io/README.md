# config_io

借助仓颉宏能力，将配置文件的读取、写入、加密、校验、监听等操作收敛到一行注解。声明即绑定，字段即配置。

---

仓颉语言本身缺少对配置文件的系统化支持。开发者通常需要手动调用 JSON/YAML 解析器、逐字段提取值、处理类型转换、自行实现加密和持久化逻辑。当配置结构嵌套较深、多源合并、敏感字段需要加密时，样板代码会迅速膨胀。

本库通过编译期宏展开，将上述全部流程折叠进 `@config` 及配套注解。你只需声明一个类、标注字段，宏会在类加载时自动完成注册、文件读取、解密、展平、类型推导和实例同步。运行时通过 `ref().get()` 获取实例，直接读写原生字段，调用 `sync()` 推回注册表触发监听与持久化。

---

## 支持的格式

| 格式 | 扩展名 | 嵌套支持 | 备注 |
|------|--------|----------|------|
| JSON | `.json` | 完整 | 标准语法 |
| YAML | `.yaml` `.yml` | 完整 | 经 yaml4cj 解析；ENC 标量自动加引号 |
| XML | `.xml` | 完整 | 扁平 `<entry key>` 和嵌套 `<app><name>` 两种写法 |
| TOML | `.toml` | 子集 | `[table]` + `key = value` + `#` 注释 |
| INI | `.ini` | 扁平 | `[section]` + `#`/`;` 注释 |
| CONF | `.conf` | 扁平 | 与 INI 共用解析器 |
| ENV | `.env` | 扁平 | `key=value` + `#` 注释 + `export` 前缀剥离 |
| AUTO | — | — | 按扩展名推断，无法推断时默认 YAML |

INI 和 CONF 仅支持扁平键值，写入嵌套结构会触发 `onError` 回调。如需嵌套，使用 JSON、YAML 或 XML。

---

## 快速开始

### 1. 声明配置类

```cangjie
import config_io.macros.*
import config_io.*
import config_io.crypto.*

@config[file = "config/app.json", id = "app"]
class AppConfig {
    // 显式声明键路径，映射嵌套 JSON
    @key[key = "app.name"]
    var appName: String = ""
    @key[key = "server.port"]
    var serverPort: String = "0"

    // 自动字段识别：无 @key 时 configKey = 字段名本身
    var timeout: String = "30"

    // 加密字段：自动注册敏感、读写时透明加解密
    @encrypt[algorithm = "sym:enc:v1"]
    var databasePassword: String = ""

    // 正则校验：写入前验证
    @verify[pattern = "^\\d+$"]
    @key[key = "server.port"]
    var validatedPort: String = "0"
}
```

对应的 `config/app.json`：

```json
{
  "app": { "name": "my-service" },
  "server": { "port": "8080" },
  "timeout": "60",
  "database": { "password": "ENC:v1:..." }
}
```

### 2. 读写配置

类加载时自动注册并读取文件。通过 `ref().get()` 获取实例，直接读写原生字段，调用 `sync()` 将修改推回注册表：

```cangjie
// 读取 — ref().get() 返回所有字段已同步的实例
let config = AppConfig.ref().get()
let name = config.appName           // "my-service"
let port = config.serverPort        // "8080"

// 写入 — 直接修改字段，调用 sync() 推回注册表（触发 onChange + 校验 + 持久化）
config.appName = "new-name"
config.sync()

// 单字段同步 — 只推送指定字段到注册表
config.syncField("serverPort")

// 辅助读写 — 通过字符串 key 动态访问（用于编译期未知的字段）
config.setField("custom.key", "value")
let val = config.getField("custom.key")

// 静态快捷方法
AppConfig.storeField("custom.key", "value")   // 直接写入注册表
AppConfig.removeField("custom.key")            // 删除字段

// 手动保存
Config.save("AppConfig", "app")

// 从磁盘重载
Config.reload("AppConfig", "app")
```

### 3. 监听器

在类内声明回调方法，用注解挂钩：

```cangjie
@config[file = "config/app.json", id = "app"]
class AppConfig {
    @key[key = "app.name"]
    var appName: String = ""

    @onLoaded[method = "handleLoaded"]
    var _hook1: Int64 = 0

    @onChange[method = "handleChange", field = "app.name"]
    var _hook2: Int64 = 0

    @onSaved[method = "handleSaved"]
    var _hook3: Int64 = 0

    public func handleLoaded(ref: ConfigRef<Any>): Unit {
        println("配置加载完成")
    }

    public func handleChange(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {
        println("字段 ${field} 已变更")
    }

    public func handleSaved(): Unit {
        println("配置已保存")
    }
}
```

六类监听器：`@onLoaded`、`@onChange`、`@onSaved`、`@onReloaded`、`@onError`、`@onValidationError`。其中 `@onChange` 和 `@onValidationError` 支持 `field` 过滤，仅匹配指定字段时才回调。

---

## 核心特性

### 自动字段识别

无需逐个声明 `@key`。`@config` 宏在编译期解析类声明，将所有未被 `@key`/`@encrypt`/`@verify` 标注的成员变量自动纳入配置管理，`configKey` 直接使用字段名本身（不做驼峰拆分）。基础类型（String/Int64/Bool/Float64 等）为扁平字段，非基础类型（Array/HashMap）为嵌套字段，从原始 JSON 树按路径直接读取。

```cangjie
@config[file = "config/app.json", id = "auto"]
class AutoConfig {
    var appName: String = ""           // configKey = "appName"
    var serverPort: String = "0"       // configKey = "serverPort"
    var tags: Array<String> = ...      // 嵌套字段，从 JSON "tags" 数组读取
    var metadata: HashMap<String, String> = ...  // 嵌套字段，从 JSON "metadata" 对象读取
}
```

需要将字段映射到嵌套路径时，用 `@key` 显式声明：

```cangjie
@key[key = "app.name"]
var appName: String = ""    // configKey = "app.name"，读取 JSON 中 app.name 的值
```

### 嵌套与非嵌套自动解析

配置库同时支持扁平和嵌套两种配置结构，解析逻辑自动适配：

- **嵌套 JSON/YAML**：`{"app": {"name": "x"}}` 在加载时展平为 `app.name`，通过 `@key[key = "app.name"]` 映射到字段。
- **扁平 INI/CONF/ENV**：`app.name=x` 直接作为扁平键读取。
- **嵌套 XML**：`<app><name>x</name></app>` 递归解析为嵌套对象，再展平为点分键。
- **basePath**：`@config[basePath = "app"]` 从 JSON 的 `app` 子对象开始读取，字段路径相对于此前缀。

### 多源合并与优先级

通过 `ConfigSource` 声明多个配置文件来源，按 `priority` 升序逐层叠加，高优先级覆盖低优先级的同名字段：

```cangjie
Config.registerFull(
    "AppConfig", "config/default.json", "app",
    "", Format.AUTO,
    [
        ConfigSource(Format.JSON, "config/default.json", "", 0, false),
        ConfigSource(Format.JSON, "config/override.json", "", 1, false)
    ],
    [ /* FieldInfo 列表 */ ],
    false, true, false, false
)
```

`firstExists = true` 模式下，找到首个存在的文件即停止加载后续来源。

### 环境变量覆盖

两种模式：

- **字段级**：`@key[env = "APP_NAME"]` 使该字段从环境变量取值，优先级高于所有文件层。
- **源模式**：`@config[env = true, prefix = "APP_"]` 跳过文件加载，所有字段从环境变量读取。字段名自动转为大写下划线格式拼接前缀（`serverPort` + `APP_` → `APP_SERVER_PORT`）。

### 加密

`@encrypt` 注解声明敏感字段，读写时透明加解密。密文格式 `ENC:v1:` + Base64(`nonce(16) || ciphertext || mac(32)`)，采用 SHA256 流密钥 XOR + HMAC-SHA256 Encrypt-then-MAC，常量时间 MAC 比较。密钥由 `KeyManager` 自动管理，支持环境变量指向密钥文件、默认路径、自动生成三种来源。整段配置文件加密时，递归遍历 JSON 树，仅对已注册的敏感字段名加解密。

### 文件监听与自动同步

`@config[autosync = true]`（默认开启）启用后台线程轮询文件变更。检测到修改后自动重载配置并分发 `onReloaded` 事件。`autosave = true` 时字段变更后自动写入文件。

### CRUD 与类型安全访问

宏为每个 `@config` 类生成 `ref()`、`sync()`、`syncField(field)`、`getField(key)`、`setField(key, value)`、`storeField(key, value)`、`removeField(key)`、`validateField(key)` 等方法。`ref().get()` 返回类型安全的实例，字段通过原生属性直接读写，`sync()` 将修改批量推回注册表。`getField`/`setField` 作为辅助手段，支持通过字符串 key 动态访问编译期未知的字段。`ConfigRef<T>` 提供类型安全的实例引用和 `set(field, value)` 重载，`ConfigMap` 支持 `[]` 链式访问嵌套结构。

---

## 宏注解一览

| 注解 | 作用对象 | 用途 |
|------|----------|------|
| `@config` | class / struct | 声明配置类，触发注册、加载、实例同步 |
| `@key` | 成员变量 | 指定 configKey 别名或嵌套路径，支持 `env` 环境变量覆盖 |
| `@encrypt` | 成员变量 | 声明加密字段，自动注册敏感 |
| `@verify` | 成员变量 | 设置正则校验模式，写入前验证 |
| `@onChange` | 成员变量 | 字段值变更回调，支持 `field` 过滤 |
| `@onLoaded` | 成员变量 | 配置加载完成回调 |
| `@onSaved` | 成员变量 | 配置保存完成回调 |
| `@onReloaded` | 成员变量 | 配置重载完成回调 |
| `@onError` | 成员变量 | 配置错误回调 |
| `@onValidationError` | 成员变量 | 字段校验失败回调，支持 `field` 过滤 |

### `@config` 属性参数

| 属性 | 缺省值 | 说明 |
|------|--------|------|
| `file` | `"config.yaml"` | 主配置文件路径 |
| `files` | `""` | 多文件来源（逗号分隔） |
| `id` | `"default"` | 实例标识 |
| `basePath` | `""` | 逻辑根路径，加载时剥离此前缀 |
| `autosave` | `false` | 字段变更后自动写文件 |
| `autosync` | `true` | 启用文件监听同步 |
| `validate` | `false` | 是否启用校验 |
| `env` | `false` | 环境变量源模式 |
| `prefix` | `""` | 环境变量名前缀（仅 `env=true` 时生效） |

---

## 项目结构

```
config/
├── src/
│   ├── macros/
│   │   └── config_macro.cj          # 宏展开（@config/@key/@encrypt/@verify/监听器宏）
│   ├── crypto/
│   │   ├── config_crypto_service.cj # 加解密服务
│   │   ├── key_manager.cj           # 密钥管理
│   │   ├── secret_seal.cj           # ENC:v1 密文封装
│   │   ├── registry_tree_load.cj    # 多源合并加载
│   │   └── yaml_persist_handler.cj  # 持久化处理器
│   ├── registry.cj                  # ConfigRegistry + Config 门面 + ConfigMap
│   ├── config_store.cj              # 字段存储
│   ├── config_validator.cj          # 正则校验
│   ├── config_merger.cj             # 字段/来源合并器
│   ├── config_persister.cj          # 同步持久化
│   ├── config_file_watcher.cj       # 文件监听
│   ├── listener_manager.cj          # 监听器管理
│   ├── format_codec.cj              # 格式编解码（7 种格式）
│   ├── file_read.cj                 # 文件读取
│   ├── sensitive_field_registry.cj  # 敏感字段注册表
│   └── types.cj                     # 数据契约（DynamicValue/FieldInfo/ConfigRef 等）
├── doc/                             # 文档目录（TPC 规范）
│   ├── assets/                      # 文档资源（图片、图表）
│   ├── design.md                    # 设计文档
│   ├── feature_api.md               # API 接口文档
│   ├── ARCHITECTURE.md              # 架构文档
│   └── MODULE_CAPABILITIES.md       # 模块能力清单
├── test/                   # 测试套件（298 项断言）
│   ├── config/                      # 测试用配置文件（7 格式 × 多场景）
│   └── src/
│       ├── format_tests/            # R1-R3: 7 格式解析 + 字段映射 + 类型支持
│       ├── encrypt_tests/           # R4: 加密机制全格式覆盖
│       ├── verify_tests/            # R5: 正则校验
│       ├── listener_tests/          # R6: 6 类监听器
│       ├── crud_tests/              # R7: CRUD 全格式 + 多深度 + 边界
│       ├── sync_tests/              # R8: 同步机制全格式 + 类型保持 + 边界
│       ├── merge_tests/             # R9: 多源合并 + firstExists
│       ├── env_tests/               # R11: 环境变量覆盖 + 源模式
│       ├── advanced_tests/          # R10/R12: basePath + ConfigMap + ConfigRef + 泛型 + stream
│       ├── error_tests/             # R13/R14: 错误处理 + 格式限制
│       ├── delete_persist_tests/    # 删除持久化验证（7 格式前后读写）
│       ├── common/                  # 共享断言工具
│       └── main.cj                  # 测试入口
├── .gitignore                       # 版本控制忽略规则
├── cangjie-format.toml              # 代码格式化配置
├── LICENSE                          # Apache-2.0 许可证
├── cjpm.toml
└── README.md
```

---

## 依赖

- **仓颉编译器** `cjc 1.2.0`
- **yaml4cj**（路径依赖，静态库）
- **stdx**（`stdx.encoding.json`、`stdx.crypto.digest`、`stdx.encoding.base64`，通过 `CANGJIE_STDX_PATH` 环境变量提供）

### 引用方式

在消费方的 `cjpm.toml` 中添加：

```toml
[dependencies]
config_io = { path = "" }
```

源码中引入：

```cangjie
import config_io.macros.*    // 宏注解
import config_io.*           // Config 门面、ConfigRegistry、类型
import config_io.crypto.*    // 加解密服务、树加载（启用加密时必须引入）
```

`config_io.crypto` 依赖 `config_io`，但 `config_io` 不反向依赖 `config_io.crypto`。宏生成的注册钩子调用非限定名 `installYamlCryptoPersistHandler()` 与 `registryLoadMergedIntoFieldValues()`，由消费方 `import config_io.crypto.*` 引入。因此使用加密功能时必须引入 `config_io.crypto`，否则链接报错。

---
