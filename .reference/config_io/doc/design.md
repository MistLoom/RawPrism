# config_io 库设计文档

## 描述

config_io 是基于仓颉宏能力的配置文件管理库，将配置文件的读取、写入、加密、校验、监听等操作收敛到编译期注解。开发者声明一个类、标注字段，宏在类加载时自动完成注册、文件读取、解密、展平、类型推导和实例同步。

## 架构设计

### 包结构

| 包 | 源码目录 | 职责 |
|----|----------|------|
| `config_io` | `src/`（不含 `macros/` 与 `crypto/`） | 配置注册表、字段存储、格式编解码、监听器、持久化、文件监听、验证、合并 |
| `config_io.macros` | `src/macros/` | 编译期宏展开（`@config`/`@key`/`@encrypt`/`@verify` 及六类监听器宏） |
| `config_io.crypto` | `src/crypto/` | 加解密服务、密钥管理、密文封装、注册表树加载、YAML 持久化处理器 |

### 依赖方向

```
应用代码
   │
   ├── @config 等宏（编译期）──► Config.registerWithOptions / mergeFieldInfos
   │
   ▼
Config（门面，src/registry.cj）
   │
   ▼
ConfigRegistry（注册表，src/registry.cj）
   │
   ├──► ConfigStore（字段存储）
   ├──► ConfigValidator（验证器）
   ├──► ConfigMerger（合并器）
   ├──► ListenerManager（监听器）
   ├──► ConfigPersister（持久化）
   └──► ConfigFileWatcher（文件监听）

config_io.crypto（独立分支）
   │
   ├──► ConfigCryptoService ──► SecretSealer / KeyManager / SensitiveFieldRegistry
   ├──► registryLoadMergedIntoFieldValues（树加载）
   └──► YamlCryptoPersistHandler / installYamlCryptoPersistHandler（持久化处理器）
```

关键约束：`config_io.crypto` 依赖 `config_io`，但 `config_io` 不反向依赖 `config_io.crypto`。宏生成的注册钩子函数调用非限定名，由宿主模块 `import config_io.crypto.*` 引入。

### 核心组件

#### ConfigRegistry

进程内单例式注册表，持有 ConfigStore、ListenerManager、ConfigValidator、ConfigPersister、ConfigFileWatcher、ConfigMerger 和 diskLoader。提供 register/get/set/setSilent/removeField/save/reload/on/off 方法。

#### ConfigStore

以 `typeName:id` 为键存储 ConfigInfo、实例引用和字段值快照，内置 AtomicBool 缓存开关。

#### format_codec

多格式编解码器，支持 JSON/YAML/ENV/INI/CONF/TOML/XML 七种格式的解析与序列化。解析时将嵌套 JSON 展平为点分键路径。

#### YamlCryptoPersistHandler

持久化处理器，按格式区分写入方式：扁平格式（TOML/INI/ENV/CONF）使用 `put(k, v)` 直接写点分键；嵌套格式（JSON/YAML/XML）使用 `putNestedField` 写嵌套结构。

## 依赖关系

- `config_io` 依赖 `yaml4cj`（YAML 编解码）
- `config_io` 依赖 `stdx`（`stdx.encoding.json`、`stdx.crypto.digest`、`stdx.encoding.base64`）
- `config_io.crypto` 依赖 `config_io`
- `config_io.macros` 依赖 `std.ast.*`

## 设计约束

- INI 和 CONF 格式仅支持扁平键值，写入嵌套结构触发 `onError` 回调
- `autosync` 默认为 true，`sync()` 自动持久化到文件；设为 false 时分离 sync（更新注册表）和 save（写文件）
- `@encrypt` 字段在 save() 时加密为 `ENC:v1:` 前缀，reload() 时透明解密
- 环境变量 API 使用 `std.env`（`getVariable`/`setVariable`/`removeVariable`）
- 仓颉 enum 类型不支持 `==` 运算符，比较时使用 match 表达式
