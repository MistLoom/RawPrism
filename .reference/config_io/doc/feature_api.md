# config_io 库 API 接口文档

## 宏注解

### @config（类/结构体级宏）

作用于 `class` 或 `struct` 声明，注册配置类并绑定配置文件。

```cangjie
@config[file = "config/app.json", id = "app"]
class AppConfig {
    var appName: String = ""
}
```

| 属性 | 类型 | 缺省值 | 说明 |
|------|------|--------|------|
| `file` | String | `"config.yaml"` | 主配置文件路径 |
| `files` | String | `""` | 多配置文件来源，逗号分隔 |
| `id` | String | `"default"` | 实例标识 |
| `basePath` | String | `""` | 逻辑根路径 |
| `autosave` | Bool | `false` | 字段变更后自动写主文件 |
| `autosync` | Bool | `true` | 启用文件监听同步；为真时 set 后亦持久化 |
| `validate` | Bool | `false` | 是否启用校验 |
| `stream` | Bool | `false` | 流式读取模式 |
| `bindRegistry` | Bool | `true` | 是否启用读盘和 extend 实例方法 |
| `env` | Bool | `false` | 环境变量源模式 |
| `prefix` | String | `""` | 环境变量名前缀（仅 env=true 时生效） |

### @key（成员宏）

将字段映射到配置文件中的键路径。

```cangjie
@key[key = "app.name"]
var appName: String = ""
```

| 属性 | 缺省 | 说明 |
|------|------|------|
| `key` | 成员名 | configKey 别名 |
| `path` | configKey | 点分路径 |
| `env` | `""` | 环境变量名，优先级高于文件层 |
| `fieldTypeName` | 声明类型 | 类型名 |

### @encrypt（成员宏）

声明敏感字段，读写时透明加解密。

```cangjie
@encrypt[algorithm = "sym:enc:v1"]
var databasePassword: String = ""
```

| 属性 | 缺省 | 说明 |
|------|------|------|
| `algorithm` | `"sym:enc:v1"` | 加密算法标识 |
| `key` | 成员名 | configKey |
| `path` | 成员名 | 点分路径 |

自动行为：`sensitive` 强制为 true；合并后对 configKey 登记 SensitiveFieldRegistry。

### @verify（成员宏）

设置正则校验，写入前验证字段值。

```cangjie
@verify[pattern = "^\\d+$"]
var serverPort: String = "0"
```

| 属性 | 说明 |
|------|------|
| `pattern` | 正则表达式（必填） |

### 监听器宏

| 宏 | 说明 |
|----|------|
| `@onLoaded[method = "onLoaded"]` | 配置加载完成时触发 |
| `@onChange[method = "onChange", field = "server.port"]` | 字段变更时触发，可选 field 过滤 |
| `@onSaved[method = "onSaved"]` | 配置保存完成时触发 |
| `@onReloaded[method = "onReloaded"]` | 配置重载完成时触发 |
| `@onError[method = "onError"]` | 配置错误时触发 |
| `@onValidationError[method = "onValidationError"]` | 校验失败时触发 |

---

## 宏生成的实例方法

### ref

```cangjie
public func ref(): ConfigRef<Self>
```

返回当前配置类的类型安全引用。`ref().get()` 返回所有字段已从注册表同步的实例。

### sync

```cangjie
public func sync(): Unit
```

将所有实例字段推回注册表，触发 onChange 监听器。`autosync=true` 时自动持久化到文件；`autosync=false` 时仅更新注册表内存。

### syncField

```cangjie
public func syncField(field: String): Unit
```

将指定字段推回注册表。

### getField

```cangjie
public func getField(key: String): String
```

动态读取字段值（编译期未知的字段）。

### setField

```cangjie
public func setField(key: String, value: String): Unit
```

动态写入字段值（编译期未知的字段）。

---

## Config 门面类静态方法

### Config.fieldAsString

```cangjie
public static func fieldAsString(typeName: String, id: String, field: String): String
```

从注册表读取字段值并返回字符串表示。

### Config.storeField

```cangjie
public static func storeField(typeName: String, id: String, field: String, value: String): Unit
```

向注册表写入字段值，触发验证和变更通知。

### Config.removeField

```cangjie
public static func removeField(typeName: String, id: String, field: String): Unit
```

从注册表删除字段。

### Config.save

```cangjie
public static func save(typeName: String, id: String): Unit
```

将注册表持久化到配置文件。

### Config.reload

```cangjie
public static func reload(typeName: String, id: String): Unit
```

从配置文件重新加载到注册表。

### Config.validateField

```cangjie
public static func validateField(typeName: String, id: String, field: String): Bool
```

校验字段值是否符合 @verify 正则。

### Config.mergeSources

```cangjie
public static func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit
```

按 ConfigSource 的 priority 升序逐层叠加合并多个配置文件。

### Config.fieldAsArrayString

```cangjie
public static func fieldAsArrayString(typeName: String, id: String, field: String): Array<String>
```

读取数组字段并返回字符串数组。

### Config.fieldAsMapString

```cangjie
public static func fieldAsMapString(typeName: String, id: String, field: String): HashMap<String, String>
```

读取映射字段并返回字符串键值对。

---

## ConfigMap 链式访问

```cangjie
let cm = Config.ref("AppConfig", "app").getMap()
let value = cm["app"]["name"].toDynamicValue()
cm["app"]["name"].set("new-value")
```

通过 `cm[key]` 链式访问嵌套路径，支持 `toDynamicValue()` 读取和 `set(value)` 写入。

---

## ConfigRef<T> 类型安全引用

```cangjie
let cfg: ConfigRef<AppConfig> = AppConfig.ref()
let instance: AppConfig = cfg.get()
cfg.set("appName", "new-name")
```

`get()` 返回字段已同步的实例；`set(field, value)` 写入注册表。

---

## ConfigSource 结构体

```cangjie
public struct ConfigSource {
    public let format: Format
    public let file: String
    public let prefix: String
    public let priority: Int64
    public let firstExists: Bool
}
```

声明多源合并的配置来源。`priority` 升序叠加；`firstExists=true` 时找到首个存在的文件即停止。
