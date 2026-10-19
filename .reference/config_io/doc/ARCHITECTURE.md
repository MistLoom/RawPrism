# config_io 模块架构文档

## 1 模块总览

### 1.1 包结构

本模块由两个包组成，编译为静态库（`output-type = "static"`），`cjc-version = "1.2.0"`，包名 `config_io`，版本 `1.0.0`。

| 包 | 源码目录 | 职责 |
|----|----------|------|
| `config_io` | `src/`（不含 `macros/` 与 `crypto/`） | 配置注册表、字段存储、格式编解码、监听器、持久化、文件监听、验证、合并、数据契约 |
| `config_io.macros` | `src/macros/` | 编译期宏展开（`@config`/`@key`/`@encrypt`/`@verify` 及六类监听器宏） |
| `config_io.crypto` | `src/crypto/` | 加解密服务、密钥管理、密文封装、注册表树加载、YAML 持久化处理器 |

依赖关系（见 `cjpm.toml`）：

- `config_io` 依赖 `yaml4cj`（路径 `../yaml4cj`，静态库），用于 YAML 编解码。
- `config_io` 依赖 `stdx`（`stdx.encoding.json`、`stdx.crypto.digest`、`stdx.encoding.base64`），通过 `bin-dependencies` 的 `CANGJIE_STDX_PATH` 提供。
- `config_io.crypto` 依赖 `config_io`（`import config_io.*`），用于调用 `ConfigRegistry`、`format_codec`、数据契约类型。
- `config_io.macros` 依赖 `std.ast.*`，独立于运行时包。

### 1.2 依赖方向

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
   ├──► ConfigStore（字段存储，src/config_store.cj）
   ├──► ConfigValidator（验证器，src/config_validator.cj）
   ├──► ConfigMerger（合并器，src/config_merger.cj）
   ├──► ListenerManager（监听器，src/listener_manager.cj）
   ├──► ConfigPersister（持久化，src/config_persister.cj）
   └──► ConfigFileWatcher（文件监听，src/config_file_watcher.cj）

config_io.crypto（独立分支）
   │
   ├──► ConfigCryptoService ──► SecretSealer / KeyManager / SensitiveFieldRegistry
   ├──► registryLoadMergedIntoFieldValues（树加载，registry_tree_load.cj）
   └──► YamlCryptoPersistHandler / installYamlCryptoPersistHandler（持久化处理器）
```

**关键约束**：`config_io.crypto` 依赖 `config_io`，但 `config_io` 不反向依赖 `config_io.crypto`。为打破循环，宏生成的注册钩子函数中调用的是非限定名 `installYamlCryptoPersistHandler()` 与 `registryLoadMainFileIntoFieldValues()`，由宿主模块 `import config_io.crypto.*` 引入。

---

## 2 核心组件说明

### 2.1 ConfigRegistry（配置注册表）

源文件：`src/registry.cj`

进程内单例式注册表，持有以下静态成员：

| 静态成员 | 类型 | 说明 |
|----------|------|------|
| `lock` | `Mutex` | 保护 `diskLoader` 的读写 |
| `store` | `ConfigStore` | 字段存储与实例映射 |
| `listenerManager` | `ListenerManager` | 监听器管理 |
| `validator` | `ConfigValidator` | 字段验证器 |
| `persister` | `ConfigPersister` | 持久化器 |
| `fileWatcher` | `ConfigFileWatcher` | 文件变更监听 |
| `merger` | `ConfigMerger` | 字段/来源合并器 |
| `diskLoader` | `?ConfigDiskLoader` | 磁盘加载器（可替换） |

核心方法：

- `register(typeName, info, id)`：注册配置元数据，重复键抛 `REGISTRATION_ERROR`。
- `get(typeName, id)` / `getRef(typeName, id)`：获取实例或 `ConfigRef<Any>`。
- `set(typeName, id, field, value)`：写入字段，触发验证、变更通知；INI/CONF 格式拒绝嵌套值；`autosave || autosync` 为真时随后持久化。
- `setSilent(typeName, id, field, value)`：验证后写入，不广播变更。
- `removeField(typeName, id, field)`：删除字段，存在则 `autosave || autosync` 时持久化。
- `save(typeName, id)`：同步持久化 + 分发 `onSaved`。
- `reload(typeName, id)`：通过 `diskLoader` 或文件加载 + 分发 `onReloaded`。
- `on(typeName, id, listener)` / `off(...)`：注册/注销监听器。

### 2.2 ConfigStore（字段存储）

源文件：`src/config_store.cj`

以 `typeName:id` 为键存储配置元数据、实例引用和字段值快照。

| 字段 | 类型 | 说明 |
|------|------|------|
| `lock` | `Mutex` | 保护所有内部映射 |
| `configs` | `HashMap<String, ConfigInfo>` | 键 → 配置元数据 |
| `instanceMap` | `HashMap<String, Any>` | 键 → 业务实例 |
| `fieldValues` | `HashMap<String, HashMap<String, DynamicValue>>` | 键 → 字段名 → 动态值 |
| `configCache` | `HashMap<String, Any>` | 实例缓存 |
| `cacheEnabled` | `AtomicBool` | 缓存开关（默认 true） |

public 方法（15 个）：

| 方法 | 说明 |
|------|------|
| `register(typeName, info, id)` | 注册配置元数据，重复键抛 `REGISTRATION_ERROR` |
| `getConfigInfo(typeName, id)` | 获取配置元数据，未注册抛 `NOT_FOUND` |
| `updateConfigInfo(typeName, id, info)` | 更新配置元数据，清除实例缓存 |
| `getInstance(typeName, id)` | 获取实例（带缓存） |
| `addInstance(typeName, id, instance)` | 添加/替换实例，更新缓存 |
| `getInstanceOpt(typeName, id)` | 获取实例（返回 `?Any`，不抛异常） |
| `getFieldValue(typeName, id, field)` | 获取字段值 `?DynamicValue` |
| `hasAnyFieldValue(typeName, id)` | 是否有任意字段值 |
| `setFieldValue(typeName, id, field, value)` | 写入字段值 |
| `getFieldValuesSnapshot(typeName, id)` | 获取字段值快照（返回映射引用） |
| `resetFieldValuesFromTopLevelMap(typeName, id, m)` | 全量替换字段快照，清除实例缓存 |
| `removeFieldValue(typeName, id, field)` | 删除字段，返回是否曾存在，清除实例缓存 |
| `instances(typeName)` | 返回指定类型的所有实例 `(id, instance)` 数组 |
| `mainFileExists(typeName, id)` | 主配置文件是否存在 |
| `getAutosyncConfigs()` | 返回所有 autosync 配置供文件监听使用 |

### 2.3 ConfigCryptoService（加解密服务）

源文件：`src/crypto/config_crypto_service.cj`

负责敏感字段的自动封装/解封，树形正文统一经 `JsonValue` 处理后按存储格式序列化。

- 依赖 `KeyManager.loadKey()` 获取 32 字节主密钥，构造 `SecretSealer`。
- 敏感键判定唯一来源：`SensitiveFieldRegistry.isRegistered(fieldName)`，无内置默认键表。
- 单值：`encryptValue` / `decryptValue` / `isEncryptedValue`。
- 整段文本：`encryptConfigText(content, storageFmt)` / `decryptConfigText(content, storageFmt)`，内部流程为「解析为 JsonValue → 递归加/解密树 → 按格式序列化」。
- 敏感键值为字符串数组时，对每个字符串元素逐项封装/解封。
- 旧前缀 `ENC:AES256:` 识别但无法解封，返回原文并提示重新保存。

public 方法（9 个）：

| 方法 | 说明 |
|------|------|
| `init()` | 加载主密钥并构造 `SecretSealer` |
| `isSensitiveField(fieldName)` | 是否为敏感键（查询 `SensitiveFieldRegistry`） |
| `isEncryptedValue(value)` | 是否为已封装的密文（`ENC:v1:` 或 `ENC:AES256:` 前缀） |
| `encryptValue(value)` | 封装单个字符串值 |
| `decryptValue(stored)` | 解封单个字符串值 |
| `serializeJsonTreeForStorage(root, storageFmt)` | 将 JsonValue 按存储格式序列化为文本 |
| `decryptConfigText(content, storageFmt)` | 解密整段配置文本 |
| `encryptConfigText(content, storageFmt)` | 加密整段配置文本 |
| `encryptJsonValue(value)` | 递归加密 JSON 树（public） |

> `decryptJsonValue` 为 private 方法，与 `encryptJsonValue` 对称地递归解密 JSON 树。

### 2.4 ConfigDiskLoader（磁盘加载器）

源文件：`src/registry.cj`（接口定义）、`src/crypto/yaml_persist_handler.cj`（实现）

```
public interface ConfigDiskLoader {
    func loadIntoRegistry(typeName: String, id: String): Unit
}
```

实现类 `YamlCryptoDiskLoader`（私有，`config_io.crypto` 包）委托 `registryLoadMergedIntoFieldValues` 完成多源合并加载。通过 `ConfigRegistry.setDiskLoader` 注入，同时传递给 `ConfigFileWatcher`。

### 2.5 FormatCodec（格式编解码）

源文件：`src/format_codec.cj`

提供配置文本与 `JsonValue` 之间的双向转换，以及嵌套对象展平。

| 公开函数 | 签名 | 说明 |
|----------|------|------|
| `parseConfigTextByFormat` | `(text: String, fmt: Format) -> JsonValue` | 按格式解析文本为 JsonValue |
| `serializeJsonValueByFormat` | `(root: JsonValue, fmt: Format) -> String` | 将 JsonValue 序列化为指定格式文本 |
| `flattenJsonObjectForRegistry` | `(root: JsonValue) -> JsonObject` | 嵌套对象展平为点分键 |
| `normalizeYamlEncScalarsInText` | `(yaml: String) -> String` | YAML 中 ENC 标量加引号 |

### 2.6 SensitiveFieldRegistry（敏感字段注册表）

源文件：`src/sensitive_field_registry.cj`

编译期或运行时显式登记的敏感字段名集合（`HashSet<String>`），按 JSON 对象键名匹配，任意嵌套深度。`ConfigCryptoService` 仅据此判定是否加密，无内置默认键名或启发式。

- `register(fieldName)`：登记一个敏感字段名。
- `isRegistered(fieldName)`：查询是否已登记。
- 线程安全：`Mutex` + `synchronized`。

`ConfigMerger.syncSensitiveRegistryForFields` 在合并字段元数据后，对 `sensitive == true` 或 `cryptoAlgorithm` 非空的字段按 `configKey` 自动登记。

### 2.7 ConfigValidator（验证器）

源文件：`src/config_validator.cj`

在 `ConfigRegistry.set` / `setSilent` 写入前执行字段验证。

- 查找 `FieldInfo`（按 `configKey` 或 `memberName` 匹配）。
- 若 `verifyPattern` 非空，用 `std.regex.Regex` 匹配 `value.toString()`。
- 匹配失败：先调用 `listenerManager.dispatchValidationError`，再抛 `ConfigException("VALIDATION_ERROR", ...)`。

---

## 3 宏系统说明

源文件：`src/macros/config_macro.cj`，宏包 `config_io.macros`。

### 3.1 @config（类/结构体级宏）

作用于 `class` 或 `struct` 声明，非侵入式展开为注册调用。

**属性参数**：

| 属性 | 缺省值 | 说明 |
|------|--------|------|
| `file` | `"config.yaml"`（无 `files` 时） | 主配置文件路径 |
| `files` | `""` | 多配置文件来源（逗号分隔或数组字面量），按优先级读取 |
| `id` | `"default"` | 实例标识 |
| `basePath` | `""` | 逻辑根路径（加载时从扁平键剥离此前缀） |
| `autosave` | `false` | 字段变更后写主文件 |
| `autosync` | `true` | 启用文件监听同步；为真时 `set` 后亦持久化 |
| `validate` | `false` | 是否启用校验 |
| `stream` | `false` | 流式读取模式 |
| `bindRegistry` | `true` | 是否启用读盘、`extend` 实例方法、`addInstance` 与 `dispatchLoaded` |
| `env` | `false` | 环境变量源模式：为 `true` 时跳过文件加载，所有字段从 OS 环境变量读取 |
| `prefix` | `""` | 环境变量名前缀（仅 `env=true` 时生效），如 `"APP_"` 使 `serverPort` → `APP_SERVER_PORT` |

**展开逻辑**：

1. 提取类名（token 流解析，不解析整段类体以避免与成员宏冲突）。
2. 生成 `Config.registerWithOptions` 或 `Config.registerWithFilesAndOptions` 调用。
3. 收集子消息（`@key`/`@encrypt`/`@verify` 上报的 `cfgFieldSpec`），生成 `Config.mergeFieldInfos` 调用。
4. **自动字段识别**：通过 `parseDecl` 解析完整类 tokens 为 `ClassDecl`，遍历 `cls.body.decls` 提取未被 `@key`/`@encrypt`/`@verify` 标注的普通 `VarDecl` 成员。每个字段的 `configKey` 直接使用字段名本身（如 `serverPort` → `serverPort`，`appName` → `appName`），不做驼峰拆分。通过 `isBasicType` 判断字段类型是否为基础类型（String/Int64/Bool/Float64 等），基础类型为扁平字段，非基础类型（Array/HashMap/ConfigNested 等）为嵌套字段。无需逐个声明 `@key`。
5. 生成 `extend <类名> { ... }`：`applyRegistryToInstance`、`syncInstanceToRegistry`、`sync`、`syncField`、`storeField`、`removeField`、`ref`、`validateField`、`getField`、`setField`。
6. 收集监听器子消息，生成私有监听器类与 `Config.on` 注册调用。
7. **环境变量源模式**（`env=true`）：注册后调用 `registryLoadFromEnv` 而非文件加载。每个字段的 `env` 属性由字段名驼峰转大写下划线 + `prefix` 自动推导（如 `serverPort` + 前缀 `APP_` → `APP_SERVER_PORT`），逐字段从 `getVariable` 读取并 `setSilent` 写入注册表，未设置环境变量的字段保留结构体默认值。
8. 全部包裹在 `private func __cfgYamlReg_<类名>()` 中，通过 `private static let __cfgYamlHook_<类名> = __cfgYamlReg_<类名>()` 在类加载时触发。

### 3.2 @key（成员宏，原 @alias）

声明字段的序列化读写键（`FieldInfo.configKey`）。

| 参数来源 | 属性 | 缺省 | 说明 |
|----------|------|------|------|
| 位置参数（首个字符串字面量） | — | — | configKey 别名 |
| — | `key` | 成员名 | configKey 别名（备选） |
| — | `path` | configKey | 点分路径 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `env` | `""` | 环境变量名，设置后该字段从环境变量取值（优先级高于所有文件层） |
| — | `id` | `""`（用 `@config` 的 id） | 实例标识 |

### 3.3 @encrypt（成员宏）

声明字段参与敏感封装，自动置 `sensitive = true`，写入 `cryptoAlgorithm` 和 `cryptoKeyId`。

| 参数来源 | 属性 | 缺省 | 说明 |
|----------|------|------|------|
| 位置参数 | — | `"sym:enc:v1"` | 加密算法标识 |
| — | `algorithm` | `"sym:enc:v1"` | 加密算法（备选） |
| — | `with` | — | 覆盖加密算法 |
| — | `key` | 成员名 | configKey |
| — | `path` | 成员名 | 点分路径 |
| — | `keyId` | `""` | 密钥逻辑引用 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `id` | `""` | 实例标识 |

合并后若 `sensitive` 或 `cryptoAlgorithm` 非空，对 `configKey` 登记 `SensitiveFieldRegistry`。

### 3.4 @verify（成员宏）

为字段设置正则校验模式 `verifyPattern`，写入前用 `std.regex` 匹配。

| 参数来源 | 属性 | 缺省 | 说明 |
|----------|------|------|------|
| 位置参数（首个字符串字面量） | — | （必填） | 正则表达式 |
| — | `pattern` | — | 正则表达式（备选） |
| — | `key` | 成员名 | configKey |
| — | `path` | 成员名 | 点分路径 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `id` | `""` | 实例标识 |

### 3.5 监听器宏

六类监听器宏，每类有单参数和双参数两种形式。通用属性：

| 属性 | 说明 |
|------|------|
| 位置参数（首个字符串字面量）或 `method` | 业务方法名（必填） |
| `field` | 字段过滤器，缺省 `"*"`（仅 `@onChange` 和 `@onValidationError` 生效，非 `*` 时仅匹配该字段才回调） |

| 宏 | 事件类型 | 触发时机 | 回调签名 |
|----|----------|----------|----------|
| `@onChange` | `change` | 字段值变更 | `onChanged(field, oldValue, newValue)` |
| `@onLoaded` | `loaded` | 配置加载完成 | `onLoaded(instanceRef)` |
| `@onSaved` | `saved` | 配置保存完成 | `onSaved()` |
| `@onReloaded` | `reloaded` | 配置重载完成 | `onReloaded()` |
| `@onError` | `error` | 配置错误 | `onError(error)` |
| `@onValidationError` | `validation_error` | 字段校验失败 | `onValidationError(field, message)` |

每个监听器宏生成一个私有类 `__CfgLis_<类名>_<方法名> <: BaseConfigListener`，仅实现对应事件回调（其余为空实现），回调内通过 `Config.get(typeName, id)` 取回实例后调用业务方法。注册通过 `Config.on(typeName, id, __CfgLis_...())` 完成。

---

## 4 支持的配置格式

| 格式 | 枚举值 | 扩展名 | 解析特点 |
|------|--------|--------|----------|
| JSON | `Format.JSON` | `.json` | 直接 `JsonValue.fromStr`，标准 JSON 语法 |
| YAML | `Format.YAML` | `.yaml` / `.yml` | 经 `yaml4cj.decode`；解析前对 `ENC:v1:`/`ENC:AES256:` 标量行加引号避免 YAML 解析器误判；解析失败时若内容以 `{` 或 `[` 开头则回退到 JSON |
| ENV | `Format.ENV` | `.env` | 逐行解析：`#` 注释、`export ` 前缀剥离、`key=value`、双引号值转义还原、值类型推断（bool/int/float/string） |
| INI | `Format.INI` | `.ini` | `#` 和 `;` 注释、`[section]` 段、`key=value`、段名与键名以点连接（`section.key`）、双引号/单引号值剥离 |
| CONF | `Format.CONF` | `.conf` | 与 INI 共用解析器（`semicolonComment = true`），行为完全一致 |
| TOML | `Format.TOML` | `.toml` | 子集实现：复用 INI 解析器但禁用 `;` 注释（`semicolonComment = false`），仅 `#` 注释、`[table]`、`key = value` |
| XML | `Format.XML` | `.xml` | 自定义递归解析器，支持两种格式：扁平条目 `<entry key="...">value</entry>` 和嵌套元素 `<app><name>value</name></app>`；XML 实体转义/反转义（`&` `<` `>` `"`） |
| AUTO | `Format.AUTO` | — | 按文件扩展名推断；无法推断时默认 YAML |

**XML 格式详解**：

解析支持两种写法（可混用）：

- 扁平条目：`<configuration><entry key="appName">value</entry></configuration>`，子元素的 `key` 属性作为 JSON 键。
- 嵌套元素：`<configuration><app><name>value</name></app></configuration>`，子元素标签名作为 JSON 键，支持任意深度递归。
- 同名/同 key 的多个子元素自动合并为 JSON 数组。
- 叶子节点（无子节点）从文本内容提取标量值并做类型推断。

序列化规则（`serializeJsonValueToXmlNode`）：

- 标量值：`<entry key="k">value</entry>`。
- 对象值：`<k><child>...</child></k>`（嵌套元素）。
- 数组值：生成多个同名元素。
- 输出包含 `<?xml version="1.0" encoding="UTF-8"?>` 头和 `<configuration>` 根元素。

序列化均为解析的逆过程，根必须为 JSON 对象。INI/CONF 序列化时值含换行或引号则加双引号转义；TOML 序列化用 `key = value` 格式。

---

## 5 数据流

### 5.1 加载流程（文件源模式）

```
registryLoadMergedIntoFieldValues(typeName, id)    [config_io.crypto/registry_tree_load.cj]
   │
   ├── ConfigRegistry.getConfigInfo(typeName, id)  获取 ConfigInfo
   ├── buildLayers(info)                           构建加载层（主文件 + sources，按 priority 升序排序）
   │
   ▼  遍历每一层 LoadLayer
   ├── exists(Path(layer.file))                    文件存在检查
   ├── readConfigFileText(path, stream)            读取文件全文（stream 模式用 File+readToEnd）
   ├── ConfigCryptoService.decryptConfigText(text, eff)   解密（按存储格式）
   ├── parseConfigTextByFormat(text, eff)          解析为 JsonValue
   ├── flattenJsonObjectForRegistry(jv)            展平嵌套对象为点分键
   ├── applyPrefixToFlatKey(prefix, k)             应用来源键前缀
   ├── stripBasePathPrefix(withPref, basePath)     剥离 basePath 前缀
   └── merged[stripped] = jsonToDynamicValue(val)  写入合并映射
   │
   ▼  嵌套字段读取
   ├── 对非基础类型字段，从原始 JSON 树按 configKey 点路径导航直接取值
   │
   ▼  环境变量覆盖
   ├── 遍历 info.fields，对 env 非空字段从 getVariable(env) 取值，覆盖 merged[configKey]
   │
   ▼  写入注册表
   └── ConfigRegistry.resetFieldValuesFromTopLevelMap(typeName, id, merged)   全量替换字段快照
```

### 5.1.1 加载流程（环境变量源模式，`@config[env=true]`）

```
registryLoadFromEnv(typeName, id)    [config_io.crypto/registry_tree_load.cj]
   │
   ├── ConfigRegistry.getConfigInfo(typeName, id)  获取 ConfigInfo
   │
   ▼  遍历 info.fields
   ├── 字段 env 属性非空？
   │   ├── 是 → getVariable(env) 读取 OS 环境变量
   │   │   ├── Some(val) → ConfigRegistry.setSilent(configKey, DVString(val))  逐字段写入
   │   │   └── None → 跳过，保留结构体默认值
   │   └── 否 → 跳过
   │
   └── 无文件 I/O，不创建配置文件
```

环境变量名自动推导规则：字段名驼峰转大写下划线 + `prefix` 前缀（如 `serverPort` + 前缀 `APP_` → `APP_SERVER_PORT`）。

### 5.2 展平机制

`flattenJsonObjectForRegistry` 将嵌套 JSON 对象递归展平为点分键。例如 `{"app": {"name": "x"}}` 展平为 `{"app.name": "x"}`。这使得 `Config.getField(typeName, id, "app.name")` 可直接命中。

### 5.2.1 自动字段识别与类型推导

`@config` 宏通过 `parseDecl` 将完整类 tokens 解析为 `ClassDecl`，遍历 `cls.body.decls` 中的 `VarDecl` 成员。未被 `@key`/`@encrypt`/`@verify` 标注的普通成员变量自动纳入配置管理。`configKey` 直接使用字段名本身，不做任何转换：

| 字段名 | 类型 | configKey | 说明 |
|--------|------|-----------|------|
| `appName` | `String` | `appName` | 基础类型，configKey = 字段名 |
| `serverPort` | `String` | `serverPort` | 基础类型，configKey = 字段名 |
| `timeout` | `Int64` | `timeout` | 基础类型，configKey = 字段名 |
| `features` | `Array<String>` | `features` | 非基础类型，嵌套字段 |

嵌套判断基于 `isBasicType(typeName)`：类型为 `String`/`Int64`/`Int32`/`Int16`/`Bool`/`Float64`/`Float32`/`UInt8`/`UInt16`/`UInt32`/`UInt64` 的是基础类型（扁平字段），其余（`Array<T>`/`HashMap<String, T>`/`ConfigNested` 子类等）为嵌套字段。若需将字段映射到不同的 configKey（如嵌套 JSON 中的点路径 `app.name`），使用 `@key[key = "app.name"]` 显式声明。

### 5.3 注册表到实例同步

宏在 `@config` 展开时生成 `applyRegistryToInstance()` 方法，将注册表中的字段值写回实例成员：

- 基本类型（Int64/Bool/Float64/String）：`Config.getField` → 类型转换 → 赋值给 `this.<成员名>`。
- 数组类型（`Array<T> where T <: ConfigNested`）：从 `DynamicValue.toJsonString()` 解析 JSON 数组，逐元素 `T.fromJson(obj)`。
- 映射类型（`HashMap<String, T>`）：同上，解析 JSON 对象。

反向同步 `syncInstanceToRegistry()` 将实例成员值通过 `Config.setSilent` 写回注册表（不触发变更通知），用于首次保存默认值。

### 5.4 宏生成的实例方法

`@config` 在 `extend <类名>` 中生成以下方法，支持原生字段读写与注册表同步：

- `ref()`：获取 `ConfigRef<T>`，内部调用 `applyRegistryToInstance()` 将注册表值同步到实例字段，`ref().get()` 返回类型安全的实例。
- `sync()`：将实例所有字段通过 `Config.set()` 推回注册表，触发 `onChange` 监听器、字段校验和持久化。
- `syncField(field)`：将单个字段推回注册表，通过 `match` 匹配字段名调用 `Config.set()`。
- `getField(key)` / `setField(key, value)`：辅助方法，通过字符串 key 动态读写注册表，用于编译期未知的字段。

---

## 6 CRUD API

### 6.1 宏生成的类方法

| 方法 | 签名 | 说明 |
|------|------|------|
| `ref` | `public static func ref(): ConfigRef<类名>` | 获取类型安全引用，内部同步注册表到实例 |
| `sync` | `public func sync(): Unit` | 实例字段 → 注册表（触发监听+校验+持久化） |
| `syncField` | `public func syncField(field: String): Unit` | 单字段 → 注册表 |
| `getField` | `public func getField(key: String): String` | 辅助：通过字符串 key 读取字段 |
| `setField` | `public func setField(key: String, value: String): Unit` | 辅助：通过字符串 key 写入字段 |
| `storeField` | `public static func storeField(fieldKey: String, value: String): Unit` | 写入字符串字段 |
| `removeField` | `public static func removeField(fieldKey: String): Bool` | 删除字段 |
| `validateField` | `public static func validateField(fieldKey: String): Bool` | 验证字段 |
| `applyRegistryToInstance` | `public func applyRegistryToInstance(): Unit` | 注册表 → 实例 |
| `syncInstanceToRegistry` | `public func syncInstanceToRegistry(): Unit` | 实例 → 注册表（静默） |

### 6.2 Config 门面 API

| 方法 | 说明 |
|------|------|
| `Config.getField(typeName, id, field)` | 获取字段 `?DynamicValue` |
| `Config.fieldAsString/fieldAsInt64/fieldAsBool/fieldAsFloat64` | 类型化读取 |
| `Config.putFieldString/putFieldInt64/putFieldBool/putFieldFloat64` | 类型化写入 |
| `Config.set(typeName, id, field, value)` | 写入 DynamicValue（含验证、通知、持久化） |
| `Config.setSilent(typeName, id, field, value)` | 静默写入（验证但不通知） |
| `Config.setAuto(typeName, id, field, value)` | 自动类型推断写入 |
| `Config.removeField(typeName, id, field)` | 删除字段 |
| `Config.save(typeName, id)` | 持久化 + 分发 onSaved |
| `Config.reload(typeName, id)` | 从磁盘重载 + 分发 onReloaded |
| `Config.get(typeName, id)` / `getRef` | 获取实例 |
| `Config.map(typeName, id)` | 获取 `ConfigMap` 嵌套访问器 |

---

## 7 加密机制

### 7.1 ENC:v1 封装格式

源文件：`src/crypto/secret_seal.cj`

密文格式：`ENC:v1:` + Base64(`nonce(16字节) || ciphertext || mac(32字节)`)

- **流密钥派生**：SHA256(`masterKey || nonce || counter(BE64)`) 分块生成 32 字节密钥流，与明文 XOR。
- **MAC**：HMAC-SHA256，密钥由 `SHA256(masterKey || "AIepoch:mac:v1")` 派生；输入为 `nonce || ciphertext`（Encrypt-then-MAC）。
- **解封验证**：先校验 MAC（常量时间比较 `constantTimeEq`），再解密。
- 依赖 `stdx.crypto.digest`（SHA256/HMAC）和 `stdx.encoding.base64`，无需 OpenSSL。

### 7.2 密钥管理

源文件：`src/crypto/key_manager.cj`

`KeyManager` 加载 32 字节主密钥的优先级：

1. 内存缓存 `cachedKey`。
2. 环境变量 `AI_EPOCH_ENCRYPTION_KEY_FILE` 指向的密钥文件（64 位十六进制字符）。
3. `runtimeDataRoot/.encryption_key`（若已 `setRuntimeDataRoot`）。
4. 旧路径 `.encryption_key`（若存在且 runtimeDataRoot 已设置，迁移到主路径）。
5. 旧路径 `.encryption_key`（无 runtimeDataRoot 时直接使用）。
6. 生成新密钥并写入主路径（或回退到旧路径）。

`setRuntimeDataRoot(root)` 须在首次 `loadKey` 前调用。

KeyManager public 方法（5 个）：

| 方法 | 说明 |
|------|------|
| `setRuntimeDataRoot(root)` | 设置运行时数据根目录（须在首次 `loadKey` 前调用） |
| `generateKey()` | 生成 32 字节随机密钥 |
| `loadKeyFromFile(keyPath)` | 从文件加载密钥（64 位十六进制），返回 `?Array<UInt8>` |
| `saveKeyToFile(key, keyPath)` | 将密钥以十六进制写入文件 |
| `loadKey()` | 按优先级链加载主密钥，结果缓存在 `cachedKey` |

### 7.3 敏感字段注册

源文件：`src/sensitive_field_registry.cj`

- `@encrypt` 宏合并字段元数据后，`ConfigMerger.syncSensitiveRegistryForFields` 对 `configKey` 自动登记。
- 也可运行时调用 `SensitiveFieldRegistry.register(fieldName)` 手动登记。
- `ConfigCryptoService` 仅根据 `SensitiveFieldRegistry.isRegistered` 判定敏感键，无启发式。

### 7.4 树遍历加解密

`ConfigCryptoService.encryptJsonValue`（public）/ `decryptJsonValue`（private）递归遍历 JSON 树：

- `JsonObject`：对每个键，若 `isSensitiveField(key)` 为真：
  - 值为 `JsonString`：加/解密该字符串。
  - 值为 `JsonArray`：对数组中每个 `JsonString` 元素逐项加/解密。
  - 其他：递归处理。
  - 非敏感键：递归处理。
- `JsonArray`：递归处理每个元素。
- 标量：原样返回。

### 7.5 持久化时的加密

`YamlCryptoPersistHandler.persist`（`src/crypto/yaml_persist_handler.cj`）：

1. 读取已有文件（解密后解析为 JsonObject），或新建空对象。
2. `ensureJsonPath(rootObj, basePath)` 定位到 basePath 节点。
3. 按存储格式区分写入方式：扁平格式（TOML/INI/ENV/CONF）使用 `put(k, v)` 直接写入点分键，不创建嵌套对象；嵌套格式（JSON/YAML/XML）使用 `putNestedField` 将扁平点路径键写回嵌套结构。
4. `ConfigCryptoService.encryptJsonValue(rootObj)` 加密整棵树。
5. `serializeJsonTreeForStorage(encrypted, eff)` 按格式序列化。
6. 父目录不存在则创建，写入文件。

---

## 8 监听器机制

### 8.1 BaseConfigListener 接口

源文件：`src/registry.cj`

```
public interface BaseConfigListener {
    func onLoaded(instanceRef: ConfigRef<Any>): Unit
    func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit
    func onReloaded(): Unit
    func onSaved(): Unit
    func onError(error: ConfigException): Unit
    func onValidationError(field: String, message: String): Unit
    func getId(): String
}
```

### 8.2 事件类型

| 事件 | 分发方法 | 触发时机 |
|------|----------|----------|
| Loaded | `dispatchLoaded` | `Config.dispatchLoaded` 调用时；监听器注册时若实例已存在亦触发 |
| Changed | `dispatchChanged` | `ConfigRegistry.set` 写入字段后 |
| Reloaded | `dispatchReloaded` | `ConfigRegistry.reload` 完成后；文件监听检测到变更重载后 |
| Saved | `dispatchSaved` | `ConfigRegistry.save` 完成后 |
| Error | `dispatchError` | 错误发生时 |
| ValidationError | `dispatchValidationError` | `ConfigValidator` 校验失败时 |

### 8.3 宏生成命名类注册

`@onChange` / `@onLoaded` / `@onSaved` / `@onReloaded` / `@onError` / `@onValidationError` 每个宏生成：

- 私有类 `__CfgLis_<类名>_<方法名> <: BaseConfigListener`，仅实现对应事件回调，其余为空实现。
- `getId()` 返回类名字符串。
- 回调内通过 `Config.get(typeName, id)` 取回实例，`as <类名>` 转型后调用业务方法。
- `@onChange` 和 `@onValidationError` 支持 `field` 过滤：非 `"*"` 时仅匹配该字段才回调。
- 注册语句 `Config.on(typeName, id, __CfgLis_...())` 在 `__cfgYamlReg_<类名>` 函数中执行。

### 8.4 ListenerManager

源文件：`src/listener_manager.cj`

public 方法（9 个）：

| 方法 | 说明 |
|------|------|
| `addListener(typeName, id, listener)` | 加入监听器列表；若实例已存在立即触发 `onLoaded` |
| `removeListener(typeName, id, listener)` | 按 `getId()` 匹配移除 |
| `dispatchLoaded(typeName, id)` | 分发加载完成事件 |
| `dispatchChanged(typeName, id, field, oldValue, newValue)` | 分发字段变更事件 |
| `dispatchReloaded(typeName, id)` | 分发重载完成事件 |
| `dispatchSaved(typeName, id)` | 分发保存完成事件 |
| `dispatchValidationError(typeName, id, field, message)` | 分发校验失败事件 |
| `dispatchError(typeName, id, error)` | 分发错误事件 |
| `getListenerCount(typeName, id)` | 获取监听器数量 |

`dispatch*` 方法在 `synchronized(lock)` 内取出监听器列表快照，锁外遍历回调。

---

## 9 线程安全

### 9.1 同步机制一览

| 组件 | 同步原语 | 保护范围 |
|------|----------|----------|
| ConfigStore | `Mutex lock` + `synchronized` | `configs`、`instanceMap`、`fieldValues`、`configCache` |
| ConfigStore | `AtomicBool cacheEnabled` | 缓存开关（无锁读取） |
| ConfigRegistry | `Mutex lock` + `synchronized` | `diskLoader` 读写、`info` 查询 |
| SensitiveFieldRegistry | `Mutex lock` + `synchronized` | `names` HashSet |
| ListenerManager | `Mutex lock` + `synchronized` | `listeners` 映射；分发时锁内取快照、锁外回调 |
| ConfigPersister | `Mutex lock` | `persistHandler` |
| ConfigFileWatcher | `Mutex lock` | `diskLoader`、`fileWatchSig` |
| ConfigFileWatcher | `Mutex pendingReloadsLock` | `pendingReloads` |
| ConfigFileWatcher | `AtomicBool watchRunning` | 监视线程运行标志 |

### 9.2 并发模型

- `ConfigStore` 的所有读写操作均通过 `synchronized(lock)` 串行化，保证字段快照与实例映射的一致性。
- `ConfigFileWatcher` 通过 `spawn` 启动后台线程，按 `ConfigDefaults.watchInterval`（默认 1000ms）轮询 autosync 配置的文件签名（`size + mtime`），变化时加入 `pendingReloads` 队列，批处理间隔（500ms）后统一重载。
- `ConfigPersister` 仅提供同步写入 `persistSync`，无异步队列。
- `ListenerManager` 的分发在锁外执行回调，避免监听器回调中再次操作注册表导致死锁。

### 9.3 文件监听流程

```
ConfigFileWatcher.start()
   └── spawn 线程循环：
       ├── sleep(watchInterval)
       ├── pollAutosyncFileChanges()
       │   ├── 获取所有 autosync 配置（store.getAutosyncConfigs）
       │   ├── 计算文件签名（size:mtime）
       │   └── 签名变化 → 加入 pendingReloads 队列（恒为批处理模式）
       └── processBatchReloads()
           ├── 取出 pendingReloads 快照
           └── 逐个 loader.loadIntoRegistry + dispatchReloaded
```

文件监听恒为批处理模式：签名变化后不立即重载，而是加入 `pendingReloads` 队列，由同一线程在下一轮 `processBatchReloads` 中统一处理，减少频繁重载。

---

## 10 辅助组件

### 10.1 ConfigMap（嵌套访问器）

源文件：`src/registry.cj`

通过 `Config.map(typeName, id)` 获取，支持点分路径的链式访问：`Config.map("App")["server"]["port"].set(8080)`。内部通过 `fullPath` 拼接点分键，委托 `ConfigRegistry.getField` / `set`。

### 10.2 ConfigPersister（持久化器）

源文件：`src/config_persister.cj`

同步持久化器，无异步队列。

public 方法（3 个）：

| 方法 | 说明 |
|------|------|
| `init(store)` | 构造时传入 `ConfigStore` |
| `setPersistHandler(handler)` | 设置持久化处理器（`YamlCryptoPersistHandler`） |
| `persistSync(typeName, id)` | 同步持久化：从 store 获取 ConfigInfo 和字段快照，调用 handler.persist |

### 10.3 ConfigFileWatcher（文件监听器）

源文件：`src/config_file_watcher.cj`

轮询 autosync 配置的文件签名变化，加入待重载队列后批量处理。恒为批处理模式，无开关。

public 方法（4 个）：

| 方法 | 说明 |
|------|------|
| `init(store, listenerManager)` | 构造时传入 `ConfigStore` 和 `ListenerManager` |
| `setDiskLoader(loader)` | 设置磁盘加载器 |
| `start()` | 启动后台监视线程（幂等，重复调用无效） |
| `stop()` | 停止监视线程 |

### 10.4 readConfigFileText（文件读取）

源文件：`src/file_read.cj`

`readConfigFileText(path, stream)`：`stream` 为假时 `File.readFrom`；为真时 `File` + `readToEnd` 流式读取（仍整段解析）。

### 10.5 effectiveStorageFormat（格式推断）

源文件：`src/types.cj`

`effectiveStorageFormat(filePath, declared)`：声明为 `AUTO` 时按扩展名推断，无法推断则默认 `YAML`；非 `AUTO` 直接返回声明格式。

### 10.6 installYamlCryptoPersistHandler（安装处理器）

源文件：`src/crypto/yaml_persist_handler.cj`

```
public func installYamlCryptoPersistHandler(): Unit
```

一次性安装：设置 `YamlCryptoPersistHandler` 为持久化处理器、设置 `YamlCryptoDiskLoader` 为磁盘加载器、启动文件变更监听。宏在 `bindRegistry = true` 时自动调用。
