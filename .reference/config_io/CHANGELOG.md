# CHANGELOG

## [1.0.0] - 2026-07-06

## Feature
+ 基于 `@config` 宏的声明式配置管理，一行注解绑定文件、注册字段、启用加密和校验
+ 支持 JSON、YAML、TOML、INI、XML、ENV、CONF 七种配置文件格式
+ `@key` 显式键路径映射与无 `@key` 自动字段识别
+ `@encrypt` 透明加解密（ENC:v1 封装，SHA256 流密钥 XOR + HMAC-SHA256 Encrypt-then-MAC）
+ `@verify` 正则校验，写入前验证字段值
+ 六类监听器：`@onLoaded`、`@onChange`、`@onSaved`、`@onReloaded`、`@onError`、`@onValidationError`
+ CRUD 全格式操作：`storeField`、`removeField`、`fieldAsString`
+ 同步机制：`sync()`、`syncField(field)`、`getField(key)`、`setField(key, value)`
+ 多源合并：`Config.mergeSources`，按 `priority` 升序逐层叠加，支持 `firstExists` 模式
+ 环境变量覆盖：字段级 `@key[env = "..."]` 和源模式 `@config[env = true, prefix = "..."]`
+ `basePath` 逻辑根路径、`ConfigMap` 链式访问、`ConfigRef<T>` 类型安全引用
+ `stream` 流式读取模式
+ `autosync` 机制：`sync()` 自动持久化到文件，设为 `false` 时分离 sync（更新注册表）和 save（写文件）
+ 文件监听：轮询配置文件签名变化，自动批处理重载
+ 扁平格式（TOML/INI/ENV/CONF）与嵌套格式（JSON/YAML/XML）按格式区分写入

## Bugfix
+ 无

## Remove
+ 无
