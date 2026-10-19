# config_io 模块能力清单


---

## 1 源文件职责一览

### 1.1 config_io 包（`src/`）

| 源文件 | 职责 |
|--------|------|
| `src/registry.cj` | 定义 `ConfigDiskLoader`/`BaseConfigListener`/`PersistHandler` 接口、`ConfigMap` 嵌套访问器、`ConfigRegistry` 注册表单例、`config_io` 门面类 |
| `src/config_store.cj` | `ConfigStore`：以 `typeName:id` 为键存储 `ConfigInfo`、实例引用、字段值快照，内置 `AtomicBool cacheEnabled` 缓存开关 |
| `src/config_validator.cj` | `ConfigValidator`：写入前按 `verifyPattern` 正则校验字段值，失败时分发 `onValidationError` 并抛异常 |
| `src/config_merger.cj` | `ConfigMerger`：合并 `FieldInfo` 数组（按 `memberName` 去重合并）与 `ConfigSource` 数组（追加），合并后同步敏感字段注册表 |
| `src/format_codec.cj` | 多格式编解码：`parseConfigTextByFormat`/`serializeJsonValueByFormat`（JSON/YAML/ENV/INI/CONF/TOML/XML）、`flattenJsonObjectForRegistry` 展平、YAML ENC 标量加引号 |
| `src/sensitive_field_registry.cj` | `SensitiveFieldRegistry`：敏感字段名显式登记（`HashSet<String>`），线程安全 |
| `src/types.cj` | 数据契约：`Format` 枚举、`DynamicValue` 接口及 6 种实现（`DVInt`/`DVFloat`/`DVString`/`DVBool`/`DVArray`/`DVMap`）、`FieldInfo`/`ConfigSource`/`ConfigInfo`/`ConfigMeta`/`GlobalDefaults` 结构体、`ConfigException`/`ConfigRef<T>`/`ConfigDefaults` 类、`ConfigNested<T>`/`ConfigListener<T>` 接口、`effectiveStorageFormat`/`fileSuffixFromPath`/`isBasicFieldTypeName`/`dynamicValueToJsonValue` 函数 |
| `src/listener_manager.cj` | `ListenerManager`：监听器注册/注销/事件分发（Loaded/Changed/Reloaded/Saved/Error/ValidationError） |
| `src/config_persister.cj` | `ConfigPersister`：同步持久化，委托 `PersistHandler` |
| `src/config_file_watcher.cj` | `ConfigFileWatcher`：轮询 autosync 配置文件签名变化，批处理重载，`spawn` 后台线程 |
| `src/file_read.cj` | `readConfigFileText`：配置文件全文读取（普通/流式两种模式） |

### 1.2 config_io.macros 包（`src/macros/`）

| 源文件 | 职责 |
|--------|------|
| `src/macros/config_macro.cj` | 编译期宏展开：`@config`（类级注册）、`@key`/`@encrypt`/`@verify`（成员级字段元数据）、`@onChange`/`@onLoaded`/`@onSaved`/`@onReloaded`/`@onError`/`@onValidationError`（监听器），生成注册钩子、`extend` 实例方法（`sync`/`syncField`/`getField`/`setField`/`ref` 等）、监听器类 |

### 1.3 config_io.crypto 包（`src/crypto/`）

| 源文件 | 职责 |
|--------|------|
| `src/crypto/config_crypto_service.cj` | `ConfigCryptoService`：敏感字段树遍历加解密、单值封装/解封、整段文本按格式加解密 |
| `src/crypto/key_manager.cj` | `KeyManager`：32 字节主密钥加载（缓存/环境变量指向文件/文件/生成）、`setRuntimeDataRoot`、密钥迁移、十六进制编解码 |
| `src/crypto/secret_seal.cj` | `SecretSealer`：ENC:v1 封装（SHA256 流密钥 XOR + HMAC-SHA256 Encrypt-then-MAC）、常量时间 MAC 比较 |
| `src/crypto/registry_tree_load.cj` | `registryLoadMergedIntoFieldValues`/`registryLoadMainFileIntoFieldValues`：多源合并加载（按 priority 升序叠加）、解密、展平、环境变量覆盖、写入注册表；`registryLoadFromEnv`：环境变量源模式加载（`@config[env=true]`），逐字段从 OS 环境变量读取并 `setSilent` 写入注册表 |
| `src/crypto/yaml_persist_handler.cj` | `YamlCryptoPersistHandler`：持久化时读已有文件→按格式区分写入（扁平格式 `put` 直接写点分键 / 嵌套格式 `putNestedField` 写嵌套结构）→加密→序列化→落盘；`YamlCryptoDiskLoader`；`installYamlCryptoPersistHandler` 一次性安装 |

---

## 2 宏及属性参数

### 2.1 @config（类/结构体级宏）

**形式**：`@config` 或 `@config[属性...]`，作用于 `class` 或 `struct` 声明。

| 属性 | 类型 | 缺省值 | 说明 |
|------|------|--------|------|
| `file` | String | `"config.yaml"` | 主配置文件路径（无 `files` 时；有 `files` 时取首个） |
| `files` | String | `""` | 多配置文件来源，逗号分隔，按优先级读取第一个存在的 |
| `id` | String | `"default"` | 实例标识 |
| `basePath` | String | `""` | 逻辑根路径 |
| `autosave` | Bool | `false` | 字段变更后写主文件 |
| `autosync` | String→Bool | `true` | 启用文件监听同步；为真时 `set` 后亦持久化 |
| `validate` | String→Bool | `false` | 是否启用校验 |
| `stream` | String→Bool | `false` | 流式读取模式 |
| `bindRegistry` | String→Bool | `true` | 是否启用读盘、`extend` 实例方法、`addInstance` 与 `dispatchLoaded` |
| `env` | String→Bool | `false` | 环境变量源模式：为 `true` 时跳过文件加载，所有字段从 OS 环境变量读取 |
| `prefix` | String | `""` | 环境变量名前缀（仅 `env=true` 时生效），如 `"APP_"` 使 `serverPort` → `APP_SERVER_PORT` |

### 2.2 @key（成员宏）

**形式**：`@key("别名")` 或 `@key[key = "别名", ...]`，作用于 `var`/`let` 成员声明。

| 参数来源 | 属性名 | 缺省 | 说明 |
|----------|--------|------|------|
| 位置参数（首个字符串字面量） | — | — | configKey 别名 |
| — | `key` | 成员名 | configKey 别名（备选） |
| — | `path` | configKey | 点分路径 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `env` | `""` | 环境变量名，优先级高于所有文件层 |
| — | `id` | `""`（回退到 `@config` 的 `id`） | 实例标识 |

### 2.3 @encrypt（成员宏）

**形式**：`@encrypt("算法")` 或 `@encrypt[algorithm = "...", ...]`，作用于 `var`/`let` 成员声明。

| 参数来源 | 属性名 | 缺省 | 说明 |
|----------|--------|------|------|
| 位置参数 | — | `"sym:enc:v1"` | 加密算法标识 |
| — | `algorithm` | `"sym:enc:v1"` | 加密算法（备选） |
| — | `with` | — | 覆盖加密算法（最高优先级） |
| — | `key` | 成员名 | configKey |
| — | `path` | 成员名 | 点分路径 |
| — | `keyId` | `""` | 密钥逻辑引用 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `id` | `""` | 实例标识 |

**自动行为**：`sensitive` 强制为 `true`；合并后对 `configKey` 登记 `SensitiveFieldRegistry`。

### 2.4 @verify（成员宏）

**形式**：`@verify("正则")` 或 `@verify[pattern = "...", ...]`，作用于 `var`/`let` 成员声明。

| 参数来源 | 属性名 | 缺省 | 说明 |
|----------|--------|------|------|
| 位置参数（首个字符串字面量） | — | （必填） | 正则表达式 |
| — | `pattern` | — | 正则表达式（备选） |
| — | `key` | 成员名 | configKey |
| — | `path` | 成员名 | 点分路径 |
| — | `fieldTypeName` | 声明类型 | 类型名 |
| — | `id` | `""` | 实例标识 |

### 2.5 监听器宏（@onChange/@onLoaded/@onSaved/@onReloaded/@onError/@onValidationError）

**形式**：`@onChange("方法名")` 或 `@onChange[method = "方法名", field = "字段"]`，作用于类/结构体内方法声明。

| 参数来源 | 属性名 | 缺省 | 说明 |
|----------|--------|------|------|
| 位置参数（首个字符串字面量） | — | — | 业务方法名（必填） |
| — | `method` | — | 业务方法名（备选） |
| — | `field` | `"*"` | 字段过滤器（仅 `@onChange`/`@onValidationError` 生效，非 `"*"` 时仅该字段变更才回调） |

| 宏 | 事件类型 | 回调签名 |
|----|----------|----------|
| `@onChange` | `change` | `onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue)` |
| `@onLoaded` | `loaded` | `onLoaded(instanceRef: ConfigRef<Any>)` |
| `@onSaved` | `saved` | `onSaved()` |
| `@onReloaded` | `reloaded` | `onReloaded()` |
| `@onError` | `error` | `onError(error: ConfigException)` |
| `@onValidationError` | `validation_error` | `onValidationError(field: String, message: String)` |

每个宏生成私有类 `__CfgLis_<类名>_<方法名> <: BaseConfigListener`，仅实现对应回调。

---

## 3 Public API 方法签名

### 3.1 Config（门面，`src/registry.cj`）

#### 注册

| 方法签名 | 说明 |
|----------|------|
| `public static func register(typeName: String, file: String): Unit` | 简化注册（id=default，autosync=true） |
| `public static func register(typeName: String, file: String, id: String): Unit` | 指定 id 注册 |
| `public static func registerFull(typeName: String, file: String, id: String, basePath: String, format: Format, sources: Array<ConfigSource>, fields: Array<FieldInfo>, autosave: Bool, autosync: Bool, validate: Bool, stream: Bool): Unit` | 完整参数注册 |
| `public static func registerWithOptions(typeName: String, file: String, id: String, basePath: String, autosave: Bool, autosync: Bool, validate: Bool, stream: Bool): Unit` | 8 参数注册（format=AUTO） |
| `public static func registerWithOptionsAndFields(typeName: String, file: String, id: String, basePath: String, autosave: Bool, autosync: Bool, validate: Bool, stream: Bool, fields: Array<FieldInfo>): Unit` | 注册并带字段元数据 |
| `public static func registerWithFilesAndOptions(typeName: String, file: String, id: String, basePath: String, sources: Array<ConfigSource>, autosave: Bool, autosync: Bool, validate: Bool, stream: Bool): Unit` | 注册并带多文件来源 |
| `public static func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit` | 合并字段元数据 |
| `public static func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit` | 合并多文件来源 |

#### 获取实例

| 方法签名 | 说明 |
|----------|------|
| `public static func get(typeName: String): Any` | 获取默认实例 |
| `public static func get(typeName: String, id: String): Any` | 获取指定实例 |
| `public static func getRef(typeName: String): ConfigRef<Any>` | 获取默认实例引用 |
| `public static func getRef(typeName: String, id: String): ConfigRef<Any>` | 获取指定实例引用 |
| `public static func instances(typeName: String): Array<(String, Any)>` | 枚举所有实例 |
| `public static func map(typeName: String): ConfigMap` | 获取嵌套访问器 |
| `public static func map(typeName: String, id: String): ConfigMap` | 获取指定实例嵌套访问器 |
| `public static func addInstance(typeName: String, instance: Any): Unit` | 注入实例（default） |
| `public static func addInstance(typeName: String, id: String, instance: Any): Unit` | 注入实例 |

#### 字段读取

| 方法签名 | 说明 |
|----------|------|
| `public static func getField(typeName: String, field: String): ?DynamicValue` | 读取字段（default） |
| `public static func getField(typeName: String, id: String, field: String): ?DynamicValue` | 读取字段 |
| `public static func fieldAsString(typeName: String, field: String): String` | 读取为字符串 |
| `public static func fieldAsString(typeName: String, id: String, field: String): String` | 读取为字符串 |
| `public static func fieldAsInt64(typeName: String, field: String): Int64` | 读取为 Int64 |
| `public static func fieldAsInt64(typeName: String, id: String, field: String): Int64` | 读取为 Int64 |
| `public static func fieldAsBool(typeName: String, field: String): Bool` | 读取为 Bool |
| `public static func fieldAsBool(typeName: String, id: String, field: String): Bool` | 读取为 Bool |
| `public static func fieldAsFloat64(typeName: String, field: String): Float64` | 读取为 Float64 |
| `public static func fieldAsArrayString(typeName: String, field: String): Array<String>` | 读取为字符串数组 |
| `public static func fieldAsArrayString(typeName: String, id: String, field: String): Array<String>` | 读取为字符串数组 |
| `public static func fieldAsMapString(typeName: String, field: String): HashMap<String, String>` | 读取为字符串映射 |
| `public static func fieldAsMapString(typeName: String, id: String, field: String): HashMap<String, String>` | 读取为字符串映射 |
| `public static func hasAnyFieldValue(typeName: String, id: String): Bool` | 是否有任意字段值 |
| `public static func getArray<T>(typeName: String, id: String, field: String, fromJson: (JsonObject) -> T): Array<T>` | 读取数组（泛型） |
| `public static func getMap<V>(typeName: String, id: String, field: String, fromJson: (JsonObject) -> V): HashMap<String, V>` | 读取映射（泛型） |

#### 字段写入

| 方法签名 | 说明 |
|----------|------|
| `public static func set(typeName: String, field: String, value: Int64): Unit` | 写入 Int64（default） |
| `public static func set(typeName: String, field: String, value: Int32): Unit` | 写入 Int32 |
| `public static func set(typeName: String, field: String, value: Int16): Unit` | 写入 Int16 |
| `public static func set(typeName: String, field: String, value: Bool): Unit` | 写入 Bool |
| `public static func set(typeName: String, field: String, value: Float64): Unit` | 写入 Float64 |
| `public static func set(typeName: String, field: String, value: Float32): Unit` | 写入 Float32 |
| `public static func set(typeName: String, field: String, value: String): Unit` | 写入 String |
| `public static func set(typeName: String, id: String, field: String, value: String): Unit` | 写入 String（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: Int64): Unit` | 写入 Int64（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: Int32): Unit` | 写入 Int32 |
| `public static func set(typeName: String, id: String, field: String, value: Int16): Unit` | 写入 Int16 |
| `public static func set(typeName: String, id: String, field: String, value: Bool): Unit` | 写入 Bool |
| `public static func set(typeName: String, id: String, field: String, value: Float64): Unit` | 写入 Float64 |
| `public static func set(typeName: String, id: String, field: String, value: Float32): Unit` | 写入 Float32 |
| `public static func set(typeName: String, field: String, value: Array<String>): Unit` | 写入字符串数组 |
| `public static func set(typeName: String, field: String, value: Array<Int64>): Unit` | 写入 Int64 数组 |
| `public static func set(typeName: String, field: String, value: Array<Bool>): Unit` | 写入 Bool 数组 |
| `public static func set(typeName: String, field: String, value: Array<Float64>): Unit` | 写入 Float64 数组 |
| `public static func set(typeName: String, id: String, field: String, value: Array<String>): Unit` | 写入字符串数组（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: Array<Int64>): Unit` | 写入 Int64 数组（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: Array<Bool>): Unit` | 写入 Bool 数组（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: Array<Float64>): Unit` | 写入 Float64 数组（指定 id） |
| `public static func set(typeName: String, field: String, value: HashMap<String, String>): Unit` | 写入字符串映射 |
| `public static func set(typeName: String, field: String, value: HashMap<String, Int64>): Unit` | 写入 Int64 映射 |
| `public static func set(typeName: String, field: String, value: HashMap<String, Bool>): Unit` | 写入 Bool 映射 |
| `public static func set(typeName: String, field: String, value: HashMap<String, Float64>): Unit` | 写入 Float64 映射 |
| `public static func set(typeName: String, id: String, field: String, value: HashMap<String, String>): Unit` | 写入字符串映射（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: HashMap<String, Int64>): Unit` | 写入 Int64 映射（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: HashMap<String, Bool>): Unit` | 写入 Bool 映射（指定 id） |
| `public static func set(typeName: String, id: String, field: String, value: HashMap<String, Float64>): Unit` | 写入 Float64 映射（指定 id） |
| `public static func set(typeName: String, field: String, value: DynamicValue): Unit` | 写入 DynamicValue |
| `public static func set(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 写入 DynamicValue（指定 id） |
| `public static func setAuto(typeName: String, field: String, value: String): Unit` | 自动类型推断写入 |
| `public static func setAuto(typeName: String, id: String, field: String, value: String): Unit` | 自动类型推断写入（指定 id） |
| `public static func setSilent(typeName: String, field: String, value: DynamicValue): Unit` | 静默写入（不广播） |
| `public static func setSilent(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 静默写入 |
| `public static func putFieldString(typeName: String, field: String, value: String): Unit` | 写入字符串字段 |
| `public static func putFieldString(typeName: String, id: String, field: String, value: String): Unit` | 写入字符串字段 |
| `public static func putFieldInt64(typeName: String, field: String, value: Int64): Unit` | 写入 Int64 字段 |
| `public static func putFieldInt64(typeName: String, id: String, field: String, value: Int64): Unit` | 写入 Int64 字段 |
| `public static func putFieldBool(typeName: String, field: String, value: Bool): Unit` | 写入 Bool 字段 |
| `public static func putFieldBool(typeName: String, id: String, field: String, value: Bool): Unit` | 写入 Bool 字段 |
| `public static func putFieldFloat64(typeName: String, field: String, value: Float64): Unit` | 写入 Float64 字段 |
| `public static func putFieldFloat64(typeName: String, id: String, field: String, value: Float64): Unit` | 写入 Float64 字段 |
| `public static func removeField(typeName: String, id: String, field: String): Bool` | 删除字段 |
| `public static func validateField(typeName: String, id: String, field: String): Bool` | 验证字段 |

#### 持久化与重载

| 方法签名 | 说明 |
|----------|------|
| `public static func save(typeName: String): Unit` | 保存（default） |
| `public static func save(typeName: String, id: String): Unit` | 保存 |
| `public static func reload(typeName: String): Any` | 重载（default），返回实例 |
| `public static func reload(typeName: String, id: String): Any` | 重载，返回实例 |

#### 监听器

| 方法签名 | 说明 |
|----------|------|
| `public static func on(typeName: String, listener: BaseConfigListener): BaseConfigListener` | 注册监听器（default） |
| `public static func on(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener` | 注册监听器 |
| `public static func off(typeName: String, listener: BaseConfigListener): Unit` | 注销监听器（default） |
| `public static func off(typeName: String, id: String, listener: BaseConfigListener): Unit` | 注销监听器 |
| `public static func dispatchLoaded(typeName: String): Unit` | 分发 Loaded 事件（default） |
| `public static func dispatchLoaded(typeName: String, id: String): Unit` | 分发 Loaded 事件 |

#### 元信息与开关

| 方法签名 | 说明 |
|----------|------|
| `public static func info(typeName: String): ConfigMeta` | 查询元信息（default） |
| `public static func info(typeName: String, id: String): ConfigMeta` | 查询元信息 |
| `public static func getConfigInfo(typeName: String): ConfigInfo` | 查询配置信息（default） |
| `public static func getConfigInfo(typeName: String, id: String): ConfigInfo` | 查询配置信息 |
| `public static func mainFileExists(typeName: String): Bool` | 主文件是否存在（default） |
| `public static func mainFileExists(typeName: String, id: String): Bool` | 主文件是否存在 |
| `public static func enableAutosync(typeName: String, enabled: Bool): Unit` | 切换 autosync（default） |
| `public static func enableAutosync(typeName: String, id: String, enabled: Bool): Unit` | 切换 autosync |
| `public static func enableAutosave(typeName: String, enabled: Bool): Unit` | 切换 autosave（default） |
| `public static func enableAutosave(typeName: String, id: String, enabled: Bool): Unit` | 切换 autosave |
| `public static func setDefaults(autosave: Option<Bool>, autosync: Option<Bool>, validate: Option<Bool>): Unit` | 设置全局默认 |
| `public static func getDefaults(): GlobalDefaults` | 获取全局默认 |

#### 转换工具

| 方法签名 | 说明 |
|----------|------|
| `public static func arrayToDVArray<T>(arr: Array<T>): DynamicValue where T <: DynamicValue` | 数组转 DVArray（泛型） |
| `public static func arrayToDVArray(arr: Array<String>): DynamicValue` | 字符串数组转 DVArray |
| `public static func arrayToDVArray(arr: Array<Int64>): DynamicValue` | Int64 数组转 DVArray |
| `public static func arrayToDVArray(arr: Array<Bool>): DynamicValue` | Bool 数组转 DVArray |
| `public static func arrayToDVArray(arr: Array<Float64>): DynamicValue` | Float64 数组转 DVArray |
| `public static func mapToDVMap(m: HashMap<String, DynamicValue>): DynamicValue` | 映射转 DVMap |
| `public static func mapToDVMap(m: HashMap<String, String>): DynamicValue` | 字符串映射转 DVMap |
| `public static func mapToDVMap(m: HashMap<String, Int64>): DynamicValue` | Int64 映射转 DVMap |
| `public static func mapToDVMap(m: HashMap<String, Bool>): DynamicValue` | Bool 映射转 DVMap |
| `public static func mapToDVMap(m: HashMap<String, Float64>): DynamicValue` | Float64 映射转 DVMap |
| `public static func nestedArrayToDV<T>(arr: Array<T>, elemTypeName: String): DynamicValue where T <: ConfigNested<T>` | 嵌套数组转 DVString(JSON) |
| `public static func nestedMapToDV(m: HashMap<String, DynamicValue>): DynamicValue` | 嵌套映射转 DVString(JSON) |
| `public static func nestedMapToDV(m: HashMap<String, String>): DynamicValue` | 嵌套字符串映射转 DVString(JSON) |
| `public static func nestedMapToDV(m: HashMap<String, Int64>): DynamicValue` | 嵌套 Int64 映射转 DVString(JSON) |
| `public static func nestedMapToDV(m: HashMap<String, Bool>): DynamicValue` | 嵌套 Bool 映射转 DVString(JSON) |
| `public static func nestedMapToDV(m: HashMap<String, Float64>): DynamicValue` | 嵌套 Float64 映射转 DVString(JSON) |
| `public static func nestedMapToDV<V>(m: HashMap<String, V>, keyTypeName: String, valTypeName: String): DynamicValue where V <: ConfigNested<V>` | 嵌套自定义类型映射转 DVString(JSON)（泛型） |

#### 系统控制

| 方法签名 | 说明 |
|----------|------|
| `public static func shutdown(): Unit` | 关闭配置系统（停止文件监听） |
| `public static func setDiskLoader(loader: ConfigDiskLoader): Unit` | 设置磁盘加载器 |
| `public static func startFileChangeWatcher(): Unit` | 启动文件变更监听 |
| `public static func stopFileChangeWatcher(): Unit` | 停止文件变更监听 |

### 3.2 ConfigRegistry（注册表，`src/registry.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public static func register(typeName: String, info: ConfigInfo, id: String): Unit` | 注册配置 |
| `public static func get(typeName: String, id: String): Any` | 获取实例 |
| `public static func getRef(typeName: String, id: String): ConfigRef<Any>` | 获取实例引用 |
| `public static func on(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener` | 注册监听器 |
| `public static func off(typeName: String, id: String, listener: BaseConfigListener): Unit` | 注销监听器 |
| `public static func instances(typeName: String): Array<(String, Any)>` | 枚举实例 |
| `public static func info(typeName: String, id: String): ConfigMeta` | 查询元信息 |
| `public static func save(typeName: String, id: String): Unit` | 保存 |
| `public static func reload(typeName: String, id: String): Unit` | 重载 |
| `public static func set(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 写入字段 |
| `public static func setSilent(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 静默写入 |
| `public static func enableAutosync(typeName: String, id: String, enabled: Bool): Unit` | 切换 autosync |
| `public static func enableAutosave(typeName: String, id: String, enabled: Bool): Unit` | 切换 autosave |
| `public static func addInstance(typeName: String, id: String, instance: Any): Unit` | 注入实例 |
| `public static func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit` | 合并字段 |
| `public static func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit` | 合并来源 |
| `public static func shutdown(): Unit` | 关闭 |
| `public static func startFileChangeWatcher(): Unit` | 启动监听 |
| `public static func stopFileChangeWatcher(): Unit` | 停止监听 |
| `public static func getField(typeName: String, id: String, field: String): ?DynamicValue` | 读取字段 |
| `public static func hasAnyFieldValue(typeName: String, id: String): Bool` | 是否有字段值 |
| `public static func removeField(typeName: String, id: String, field: String): Bool` | 删除字段 |
| `public static func getConfigInfo(typeName: String, id: String): ConfigInfo` | 查询配置信息 |
| `public static func mainFileExists(typeName: String, id: String): Bool` | 主文件是否存在 |
| `public static func resetFieldValuesFromTopLevelMap(typeName: String, id: String, m: HashMap<String, DynamicValue>): Unit` | 全量重置字段值 |
| `public static func setDiskLoader(loader: ConfigDiskLoader): Unit` | 设置磁盘加载器 |
| `public static func getFieldValuesSnapshot(typeName: String, id: String): HashMap<String, DynamicValue>` | 字段快照 |
| `public static func setPersistHandler(handler: PersistHandler): Unit` | 设置持久化处理器 |
| `public static func getStore(): ConfigStore` | 获取 store |
| `public static func getPersister(): ConfigPersister` | 获取 persister |
| `public static func getFileWatcher(): ConfigFileWatcher` | 获取 fileWatcher |
| `public static func dispatchLoaded(typeName: String, id: String): Unit` | 分发 Loaded 事件 |

### 3.3 ConfigStore（字段存储，`src/config_store.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public func register(typeName: String, info: ConfigInfo, id: String): Unit` | 注册 |
| `public func getConfigInfo(typeName: String, id: String): ConfigInfo` | 获取配置信息 |
| `public func updateConfigInfo(typeName: String, id: String, info: ConfigInfo): Unit` | 更新配置信息 |
| `public func getInstance(typeName: String, id: String): Any` | 获取实例（带缓存） |
| `public func addInstance(typeName: String, id: String, instance: Any): Unit` | 注入实例 |
| `public func getInstanceOpt(typeName: String, id: String): ?Any` | 获取实例（可选） |
| `public func getFieldValue(typeName: String, id: String, field: String): ?DynamicValue` | 读取字段值 |
| `public func hasAnyFieldValue(typeName: String, id: String): Bool` | 是否有字段值 |
| `public func setFieldValue(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 写入字段值 |
| `public func getFieldValuesSnapshot(typeName: String, id: String): HashMap<String, DynamicValue>` | 字段快照 |
| `public func resetFieldValuesFromTopLevelMap(typeName: String, id: String, m: HashMap<String, DynamicValue>): Unit` | 全量重置字段值 |
| `public func removeFieldValue(typeName: String, id: String, field: String): Bool` | 删除字段值 |
| `public func instances(typeName: String): Array<(String, Any)>` | 枚举实例 |
| `public func mainFileExists(typeName: String, id: String): Bool` | 主文件是否存在 |
| `public func getAutosyncConfigs(): Array<(String, ConfigInfo)>` | 获取所有 autosync 配置 |

> `cacheEnabled` 为 `AtomicBool`（源码第 13 行），控制实例缓存开关，无显式 `enableCache`/`clearCache` 方法。

### 3.4 ConfigCryptoService（加解密服务，`src/crypto/config_crypto_service.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init()` | 构造（加载密钥） |
| `public func isSensitiveField(fieldName: String): Bool` | 是否敏感字段 |
| `public func isEncryptedValue(value: String): Bool` | 是否已加密值 |
| `public func encryptValue(value: String): String` | 加密单值 |
| `public func decryptValue(stored: String): String` | 解密单值 |
| `public func serializeJsonTreeForStorage(root: JsonValue, storageFmt: Format): String` | 序列化 JSON 树 |
| `public func decryptConfigText(content: String, storageFmt: Format): String` | 解密配置文本 |
| `public func encryptConfigText(content: String, storageFmt: Format): String` | 加密配置文本 |
| `public func encryptJsonValue(value: JsonValue): JsonValue` | 加密 JSON 树 |

### 3.5 KeyManager（密钥管理，`src/crypto/key_manager.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public static func setRuntimeDataRoot(root: String): Unit` | 设置运行时数据根目录 |
| `public static func generateKey(): Array<UInt8>` | 生成 32 字节随机密钥 |
| `public static func loadKeyFromFile(keyPath: String): ?Array<UInt8>` | 从文件加载密钥 |
| `public static func saveKeyToFile(key: Array<UInt8>, keyPath: String): Unit` | 保存密钥到文件 |
| `public static func loadKey(): Array<UInt8>` | 加载密钥（带缓存，按优先级） |

**密钥优先级链**（`loadKey` → `loadKeyUncached`）：

1. 内存缓存 `cachedKey`
2. 环境变量 `AI_EPOCH_ENCRYPTION_KEY_FILE` 指向的密钥文件路径
3. 主路径 `runtimeDataRoot/.encryption_key`（未设置 `runtimeDataRoot` 时回退到 `.encryption_key`）
4. 旧版路径 `.encryption_key`（若主路径不同则尝试迁移到主路径）
5. 生成新密钥并写入主路径（失败时写入旧版路径）

### 3.6 SecretSealer（密文封装，`src/crypto/secret_seal.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(masterKey: Array<UInt8>)` | 构造（须 32 字节） |
| `public func sealString(plaintext: String): String` | 封装为 `ENC:v1:` + Base64 |
| `public func openString(stored: String): String` | 解封 |
| `public func isSealedValue(stored: String): Bool` | 是否已封装 |

### 3.7 SensitiveFieldRegistry（敏感字段注册表，`src/sensitive_field_registry.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public static func register(fieldName: String): Unit` | 登记敏感字段名 |
| `public static func isRegistered(fieldName: String): Bool` | 查询是否已登记 |

### 3.8 ConfigValidator（验证器，`src/config_validator.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(store: ConfigStore, listenerManager: ListenerManager)` | 构造 |
| `public func validateField(typeName: String, id: String, field: String, value: DynamicValue): Unit` | 验证字段 |

### 3.9 ConfigMerger（合并器，`src/config_merger.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(store: ConfigStore)` | 构造 |
| `public func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit` | 合并字段元数据 |
| `public func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit` | 合并多文件来源 |

### 3.10 ListenerManager（监听器管理，`src/listener_manager.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(store: ConfigStore)` | 构造 |
| `public func addListener(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener` | 注册监听器 |
| `public func removeListener(typeName: String, id: String, listener: BaseConfigListener): Unit` | 注销监听器 |
| `public func dispatchLoaded(typeName: String, id: String): Unit` | 分发 Loaded |
| `public func dispatchChanged(typeName: String, id: String, field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit` | 分发 Changed |
| `public func dispatchReloaded(typeName: String, id: String): Unit` | 分发 Reloaded |
| `public func dispatchSaved(typeName: String, id: String): Unit` | 分发 Saved |
| `public func dispatchError(typeName: String, id: String, error: ConfigException): Unit` | 分发 Error |
| `public func dispatchValidationError(typeName: String, id: String, field: String, message: String): Unit` | 分发 ValidationError |
| `public func getListenerCount(typeName: String, id: String): Int64` | 监听器数量 |

### 3.11 ConfigPersister（持久化器，`src/config_persister.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(store: ConfigStore)` | 构造 |
| `public func setPersistHandler(handler: PersistHandler): Unit` | 设置持久化处理器 |
| `public func persistSync(typeName: String, id: String): Unit` | 同步持久化 |

### 3.12 ConfigFileWatcher（文件监听器，`src/config_file_watcher.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(store: ConfigStore, listenerManager: ListenerManager)` | 构造 |
| `public func setDiskLoader(loader: ConfigDiskLoader): Unit` | 设置磁盘加载器 |
| `public func start(): Unit` | 启动监视线程 |
| `public func stop(): Unit` | 停止监视线程 |

### 3.13 ConfigMap（嵌套访问器，`src/registry.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(typeName: String)` | 构造（id=default） |
| `public init(typeName: String, id: String)` | 构造 |
| `public func get(key: String): ?DynamicValue` | 读取值 |
| `public operator func [](key: String): ConfigMap` | 链式嵌套访问 |
| `public func set(key: String, value: DynamicValue): Unit` | 写入 DynamicValue |
| `public func set(key: String, value: String): Unit` | 写入 String |
| `public func set(key: String, value: Int64): Unit` | 写入 Int64 |
| `public func set(key: String, value: Bool): Unit` | 写入 Bool |
| `public func set(key: String, value: Float64): Unit` | 写入 Float64 |
| `public func set(value: DynamicValue): Unit` | 写入当前路径值 |
| `public func set(value: String): Unit` | 写入当前路径值 |
| `public func set(value: Int64): Unit` | 写入当前路径值 |
| `public func set(value: Bool): Unit` | 写入当前路径值 |
| `public func set(value: Float64): Unit` | 写入当前路径值 |
| `public func toDynamicValue(): ?DynamicValue` | 转为 DynamicValue |

### 3.14 ConfigRef<T>（实例引用，`src/types.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public init(instance: T)` | 构造（无类型绑定） |
| `public init(instance: T, typeName: String, id: String)` | 构造（带类型与 id） |
| `public func get(): T` | 获取原始实例 |
| `public func set(field: String, value: String): Unit` | 写入 String |
| `public func set(field: String, value: Int64): Unit` | 写入 Int64 |
| `public func set(field: String, value: Int32): Unit` | 写入 Int32 |
| `public func set(field: String, value: Int16): Unit` | 写入 Int16 |
| `public func set(field: String, value: Bool): Unit` | 写入 Bool |
| `public func set(field: String, value: Float64): Unit` | 写入 Float64 |
| `public func set(field: String, value: Float32): Unit` | 写入 Float32 |
| `public func set(field: String, value: Array<String>): Unit` | 写入字符串数组 |
| `public func set(field: String, value: Array<Int64>): Unit` | 写入 Int64 数组 |
| `public func set(field: String, value: Array<Bool>): Unit` | 写入 Bool 数组 |
| `public func set(field: String, value: Array<Float64>): Unit` | 写入 Float64 数组 |
| `public func set(field: String, value: HashMap<String, String>): Unit` | 写入字符串映射 |
| `public func set(field: String, value: HashMap<String, Int64>): Unit` | 写入 Int64 映射 |
| `public func set(field: String, value: HashMap<String, Bool>): Unit` | 写入 Bool 映射 |
| `public func set(field: String, value: HashMap<String, Float64>): Unit` | 写入 Float64 映射 |
| `public func set(field: String, value: DynamicValue): Unit` | 写入 DynamicValue |

### 3.15 ConfigNested<T>（嵌套配置接口，`src/types.cj`）

| 方法签名 | 说明 |
|----------|------|
| `static func fromJson(jv: JsonValue): T` | 从 JsonValue 反序列化 |
| `static func defaultValue(): T` | 默认值 |
| `func toJson(): JsonValue` | 序列化为 JsonValue |

> 嵌套访问能力已折叠到 `config_io` 门面（`getArray`/`getMap`/`nestedArrayToDV`/`nestedMapToDV`）和 `ConfigNested<T>` 接口，无独立的 `ConfigBinder` 组件。

### 3.16 config_io.crypto 包公开函数（`src/crypto/`）

| 函数签名 | 源文件 | 说明 |
|----------|--------|------|
| `public func registryLoadMergedIntoFieldValues(typeName: String, id: String): Unit` | `registry_tree_load.cj` | 多源合并加载到注册表 |
| `public func registryLoadMainFileIntoFieldValues(typeName: String, id: String): Unit` | `registry_tree_load.cj` | 等价于合并加载 |
| `public func registryLoadFromEnv(typeName: String, id: String): Unit` | `registry_tree_load.cj` | 环境变量源模式加载：逐字段从 OS 环境变量读取并写入注册表 |
| `public func readEnvVar(name: String): ?String` | `registry_tree_load.cj` | 读取环境变量（供宏生成代码调用） |
| `public func installYamlCryptoPersistHandler(): Unit` | `yaml_persist_handler.cj` | 安装持久化处理器+磁盘加载器+文件监听 |

### 3.17 config_io 包公开函数（`src/`）

| 函数签名 | 源文件 | 说明 |
|----------|--------|------|
| `public func parseConfigTextByFormat(text: String, fmt: Format): JsonValue` | `format_codec.cj` | 按格式解析文本 |
| `public func serializeJsonValueByFormat(root: JsonValue, fmt: Format): String` | `format_codec.cj` | 按格式序列化 |
| `public func flattenJsonObjectForRegistry(root: JsonValue): JsonObject` | `format_codec.cj` | 展平嵌套对象 |
| `public func normalizeYamlEncScalarsInText(yaml: String): String` | `format_codec.cj` | YAML ENC 标量加引号 |
| `public func readConfigFileText(path: Path, stream: Bool): String` | `file_read.cj` | 读取配置文件 |
| `public func effectiveStorageFormat(filePath: String, declared: Format): Format` | `types.cj` | 推断存储格式 |
| `public func fileSuffixFromPath(path: String): String` | `types.cj` | 提取文件后缀 |
| `public func isBasicFieldTypeName(typeName: String): Bool` | `types.cj` | 判断类型名是否为基础类型 |
| `public func dynamicValueToJsonValue(v: DynamicValue): JsonValue` | `types.cj` | DynamicValue 转 JsonValue |

### 3.18 ConfigDefaults（全局默认，`src/types.cj`）

| 方法签名 | 说明 |
|----------|------|
| `public static func getDefaults(): GlobalDefaults` | 获取全局默认 |
| `public static func setAutosave(enabled: Bool): Unit` | 设置默认 autosave |
| `public static func setAutosync(enabled: Bool): Unit` | 设置默认 autosync |
| `public static func setValidate(enabled: Bool): Unit` | 设置默认 validate |
| `public static func setWatchInterval(ms: Int64): Unit` | 设置监视间隔 |
| `public static func reset(): Unit` | 重置为默认值 |

---

## 4 支持的格式及解析特点

| 格式 | 枚举值 | 扩展名 | 解析特点 | 序列化特点 |
|------|--------|--------|----------|------------|
| JSON | `Format.JSON` | `.json` | `JsonValue.fromStr`，标准 JSON | `root.toString()` |
| YAML | `Format.YAML` | `.yaml`/`.yml` | `yaml4cj.decode`；解析前对 `ENC:v1:`/`ENC:AES256:` 标量加引号；失败时若以 `{`/`[` 开头回退 JSON | `yaml4cj.encode` + ENC 标量加引号 |
| ENV | `Format.ENV` | `.env` | 逐行：`#` 注释、`export ` 前缀剥离、`key=value`、双引号转义还原、类型推断（bool/int/float/string） | `key=value`，含空格/换行/`#`/`=` 时双引号转义 |
| INI | `Format.INI` | `.ini` | `#` 和 `;` 注释、`[section]` 段、`key=value`、`section.key` 点连接、双引号/单引号值剥离 | `key=value`，值含换行或引号时双引号转义 |
| CONF | `Format.CONF` | `.conf` | 与 INI 共用解析器（`semicolonComment=true`），行为一致 | 与 INI 一致 |
| TOML | `Format.TOML` | `.toml` | **子集支持**：复用 INI 解析器但 `semicolonComment=false`，仅 `#` 注释、`[table]`、`key = value`。**不支持**内联表、数组表（`[[table]]`）、多行字符串、日期时间 | `key = value`，需要时双引号 |
| XML | `Format.XML` | `.xml` | 支持两种格式：扁平条目 `<entry key="...">value</entry>` 和嵌套元素 `<app><name>value</name></app>`；自定义递归解析器，XML 实体反转义；同名/同 key 子元素自动合并为数组 | `<?xml version="1.0" encoding="UTF-8"?>` + `<configuration>` 包裹；标量用 `<entry key="k">value</entry>`，对象生成嵌套元素 `<k><child>...</child></k>`，数组生成多个同名元素；XML 实体转义 |
| AUTO | `Format.AUTO` | — | 按扩展名推断，无法推断时默认 YAML | 须先 `effectiveStorageFormat` 推断 |

---

## 5 线程安全机制

| 组件 | 源文件 | 同步原语 | 保护范围 | 说明 |
|------|--------|----------|----------|------|
| ConfigStore | `config_store.cj` | `Mutex lock` + `synchronized` | `configs`、`instanceMap`、`fieldValues`、`configCache` | 所有读写操作串行化 |
| ConfigStore | `config_store.cj` | `AtomicBool cacheEnabled` | 缓存开关 | 无锁读取，`store`/`load` 原子操作 |
| ConfigRegistry | `registry.cj` | `Mutex lock` + `synchronized` | `diskLoader` 读写、`info` 查询 | 保护可变静态成员 |
| SensitiveFieldRegistry | `sensitive_field_registry.cj` | `Mutex lock` + `synchronized` | `names` HashSet | 敏感字段名集合读写 |
| ListenerManager | `listener_manager.cj` | `Mutex lock` + `synchronized` | `listeners` 映射 | 分发时锁内取快照、锁外回调，避免死锁 |
| ConfigPersister | `config_persister.cj` | `Mutex lock` | `persistHandler` | 处理器引用读写 |
| ConfigFileWatcher | `config_file_watcher.cj` | `Mutex lock` | `diskLoader`、`fileWatchSig`、`watchThreadStarted` | 监视器状态与签名 |
| ConfigFileWatcher | `config_file_watcher.cj` | `Mutex pendingReloadsLock` | `pendingReloads` | 待重载队列 |
| ConfigFileWatcher | `config_file_watcher.cj` | `AtomicBool watchRunning` | 监视线程运行标志 | `spawn` 后台线程轮询控制 |

**并发模型说明**：

- `ConfigStore` 所有操作通过 `synchronized(lock)` 串行化，保证字段快照与实例映射一致性。
- `ConfigFileWatcher` 通过 `spawn` 启动后台线程，按 `ConfigDefaults.watchInterval`（默认 1000ms）轮询 autosync 配置的文件签名（`size + mtime`），检测到变化后将待重载项加入 `pendingReloads` 队列，下一轮询周期批量处理。
- `ListenerManager` 分发在锁外执行回调，避免监听器回调中再次操作注册表导致死锁。
- `KeyManager.cachedKey` 为静态可变变量，依赖首次 `loadKey` 后缓存，无显式锁保护。
- `ConfigDefaults.__defaults__` 为静态可变变量，无显式锁保护，适用于初始化阶段单线程设置。
