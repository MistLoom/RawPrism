/*
 * Config stdx - Configuration macro package
 * 非侵入：成员宏通过 assertParentContext + setItem 向 @config 上报；@config 在类内静态初始化中调用
 * registerWithOptions + mergeFieldInfos（包级不得出现裸表达式，故生成 private func + static let 钩子）。
 *
 * v2.0 重构:
 * 1. @verify 优化：位置参数直接传正则，移除 pattern 属性
 * 2. 移除 @nested、@configField、@autosave、@autosync、@lazy
 * 3. 新增 @onChange、@onLoaded、@onSaved、@onReloaded、@onError 监听器宏
 * 4. @config 支持多配置文件来源（files 属性，逗号分隔，按优先级读取第一个存在的）
 * 5. @key 支持 env 属性，从指定环境变量读取值
 * 6. v2.1: 自动字段识别 — 无 @key 的字段自动纳入配置管理，configKey = 字段名本身（不做驼峰拆分）
 * 7. v2.1: @config[env=true] 环境变量源模式 — 所有字段从环境变量自动读取，无需文件
 * 8. v2.1: @config[autosync=true] 文件自动同步在 @config 级别声明
 */

macro package config_io.macros

import std.ast.*
import std.collection.*

private let SPEC_SEP: String = "\t"
private let SPEC_KEY: String = "cfgFieldSpec"

/// 判断类型名是否为基础类型（非嵌套）：String/Int64/Int32/Int16/Bool/Float64/Float32
/// 非基础类型（Array/HashMap/ConfigNested 子类等）视为嵌套字段
private func isBasicType(typeName: String): Bool {
    let basicTypes = ["String", "Int64", "Int32", "Int16", "Bool", "Float64", "Float32", "UInt8", "UInt16", "UInt32", "UInt64"]
    for (bt in basicTypes) {
        if (typeName == bt) {
            return true
        }
    }
    false
}

/// 驼峰转大写下划线：serverPort → SERVER_PORT, appName → APP_NAME
/// 用于 env 模式下从字段名推导环境变量名（命名约定，非结构推导）
private func camelToUpperSnake(s: String, prefix: String): String {
    let upperChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    var result = prefix
    var i: Int64 = 0
    while (i < s.size) {
        let c = s[i]
        if (c >= 0x41 && c <= 0x5A) {  // A-Z
            if (i > 0) {
                result = result + "_"
            }
            let upperIdx = Int64(c - 0x41)
            result = result + upperChars[upperIdx..upperIdx + 1]
        } else if (c >= 0x61 && c <= 0x7A) {  // a-z
            let upperIdx = Int64(c - 0x61)
            result = result + upperChars[upperIdx..upperIdx + 1]
        } else {
            result = result + s[i..i + 1]
        }
        i = i + 1
    }
    result
}
private let LISTENER_KEY: String = "cfgListenerSpec"

private func configRegFunctionName(className: String): String {
    "__cfgYamlReg_" + className
}

private func configHookStaticLetName(className: String): String {
    "__cfgYamlHook_" + className
}

private func findClassBodyOpeningBraceIndex(input: Tokens): Int64 {
    var i: Int64 = 0
    while (i < input.size) {
        if (input[i].kind == TokenKind.LCURL) {
            return i
        }
        i += 1
    }
    throw Exception("@config：未找到类体「{」")
}

private func wrapConfigExpansionWithStaticInit(
    className: String,
    registerStmt: Tokens,
    mergeBlock: Tokens,
    postRegisterBlock: Tokens,
    extendBlock: Tokens,
    listenerRegBlock: Tokens,
    listenerClassDefs: Tokens,
    classTokens: Tokens
): Tokens {
    let fnName = configRegFunctionName(className)
    let hookName = configHookStaticLetName(className)
    let fnId = Token(TokenKind.IDENTIFIER, fnName)
    let hookId = Token(TokenKind.IDENTIFIER, hookName)
    let fnDef = quote(
        private func $fnId(): Unit {
            $registerStmt
            $mergeBlock
            $listenerRegBlock
            $postRegisterBlock
        }
    )
    let hookField = quote(
        private static let $hookId: Unit = $fnId()
    )
    let openIdx = findClassBodyOpeningBraceIndex(classTokens)
    let head = classTokens[0..(openIdx + 1)]
    let tail = classTokens[(openIdx + 1)..classTokens.size]
    let nl = Token(TokenKind.NL)
    listenerClassDefs + nl + fnDef + nl + head + nl + hookField + nl + tail + nl + extendBlock
}

private class SpecMemberInfo {
    public let flavor: String
    public let memberName: String
    public let configKey: String
    public let path: String
    public let fieldType: String
    public let defaultValue: String
    public let isLazy: Bool
    public let sensitive: Bool
    public let verifyPattern: String
    public let cryptoAlgorithm: String
    public let cryptoKeyId: String
    public let env: String

    public init(
        flavor: String,
        memberName: String,
        configKey: String,
        path: String,
        fieldType: String,
        defaultValue: String,
        isLazy: Bool,
        sensitive: Bool,
        verifyPattern: String,
        cryptoAlgorithm: String,
        cryptoKeyId: String,
        env: String
    ) {
        this.flavor = flavor
        this.memberName = memberName
        this.configKey = configKey
        this.path = path
        this.fieldType = fieldType
        this.defaultValue = defaultValue
        this.isLazy = isLazy
        this.sensitive = sensitive
        this.verifyPattern = verifyPattern
        this.cryptoAlgorithm = cryptoAlgorithm
        this.cryptoKeyId = cryptoKeyId
        this.env = env
    }
}

private class ListenerSpecInfo {
    public let eventType: String
    public let methodName: String
    public let fieldFilter: String

    public init(eventType: String, methodName: String, fieldFilter: String) {
        this.eventType = eventType
        this.methodName = methodName
        this.fieldFilter = fieldFilter
    }
}

private func collectAllSpecMembers(): ArrayList<SpecMemberInfo> {
    let results = ArrayList<SpecMemberInfo>()
    // v2.0: @alias 已更名为 @key；@field 已移除。此列表须与实际宏名一致。
    let flavors = ["encrypt", "key", "verify"]
    for (fname in flavors) {
        for (m in getChildMessages(fname)) {
            if (m.hasItem(SPEC_KEY)) {
                let line = m.getString(SPEC_KEY)
                let parts = line.split(SPEC_SEP, removeEmpty: false)
                if (parts.size >= 12) {
                    let info = SpecMemberInfo(
                        parts[0],
                        parts[2],
                        parts[3],
                        parts[4],
                        parts[5],
                        parts[6],
                        parts[7] == "true",
                        parts[8] == "true",
                        parts[9],
                        parts[10],
                        parts[11],
                        if (parts.size >= 13) { parts[12] } else { "" }
                    )
                    results.add(info)
                }
            }
        }
    }
    results
}

private func collectAllListenerSpecs(): ArrayList<ListenerSpecInfo> {
    let results = ArrayList<ListenerSpecInfo>()
    // v2.0: 监听器宏名为 onChange/onLoaded/onSaved/onReloaded/onError/onValidationError，须逐一遍历。
    let listenerMacroNames = ["onChange", "onLoaded", "onSaved", "onReloaded", "onError", "onValidationError"]
    for (lname in listenerMacroNames) {
        for (m in getChildMessages(lname)) {
            if (m.hasItem(LISTENER_KEY)) {
                let line = m.getString(LISTENER_KEY)
                let parts = line.split(SPEC_SEP, removeEmpty: false)
                if (parts.size >= 3) {
                    let info = ListenerSpecInfo(parts[0], parts[1], parts[2])
                    results.add(info)
                }
            }
        }
    }
    results
}

private func extractTypeNameFromVarDecl(varDecl: VarDecl): String {
    varDecl.declType.toTokens().toString().replace(" ", "")
}

private func extractTypeNameFromVarDeclTokens(tokens: Tokens): String {
    let decl = parseDecl(tokens)
    match (decl as VarDecl) {
        case Some(v) => extractTypeNameFromVarDecl(v)
        case None => "String"
    }
}

private class PlainVarInfo {
    public let name: String
    public let typeName: String
    public let isNested: Bool

    public init(name: String, typeName: String) {
        this.name = name
        this.typeName = typeName
        this.isNested = !isBasicType(typeName)
    }
}

private func collectPlainVarsWithTypes(classTokens: Tokens, skip: HashSet<String>): ArrayList<PlainVarInfo> {
    // classTokens 应为完整类 tokens（含 class Foo { ... }），用 parseDecl 解析
    let out = ArrayList<PlainVarInfo>()
    let decl = try {
        parseDecl(classTokens)
    } catch (_: Exception) {
        return out
    }
    match (decl as ClassDecl) {
        case Some(cls) =>
            for (d in cls.body.decls) {
                match (d as VarDecl) {
                    case Some(v) =>
                        let vn = v.identifier.value
                        if (!skip.contains(vn)) {
                            let typeName = extractTypeNameFromVarDecl(v)
                            out.add(PlainVarInfo(vn, typeName))
                        }
                    case None => ()
                }
            }
        case None =>
            match (decl as StructDecl) {
                case Some(st) =>
                    for (d in st.body.decls) {
                        match (d as VarDecl) {
                            case Some(v) =>
                                let vn = v.identifier.value
                                if (!skip.contains(vn)) {
                                    let typeName = extractTypeNameFromVarDecl(v)
                                    out.add(PlainVarInfo(vn, typeName))
                                }
                            case None => ()
                        }
                    }
                case None => ()
            }
    }
    out
}

private func mergePlainVarLine(className: String, classIdDefault: String, memberName: String, typeName: String, basePath: String, envMode: Bool, envPrefix: String): Tokens {
    // configKey = 字段名本身，不做驼峰拆分；嵌套结构通过类型判断（isBasicType）而非名字猜测
    let configKey = memberName
    let fullPath = if (basePath.size > 0) { basePath + "." + configKey } else { configKey }
    let envVar = if (envMode) { camelToUpperSnake(memberName, envPrefix) } else { "" }
    let line = "A" + SPEC_SEP + classIdDefault + SPEC_SEP + memberName + SPEC_SEP + configKey + SPEC_SEP + fullPath +
        SPEC_SEP + typeName + SPEC_SEP + "__NONE__" + SPEC_SEP + "false" + SPEC_SEP + "false" + SPEC_SEP + "" + SPEC_SEP + "" +
        SPEC_SEP + "" + SPEC_SEP + envVar
    quoteMergeFromSpecLine(className, classIdDefault, line, basePath)
}

private func buildPlainFieldMerges(className: String, id: String, plainVars: ArrayList<PlainVarInfo>, basePath: String, envMode: Bool, envPrefix: String): Tokens {
    var block = Tokens()
    for (pv in plainVars) {
        block = block + mergePlainVarLine(className, id, pv.name, pv.typeName, basePath, envMode, envPrefix) + Token(TokenKind.NL)
    }
    block
}

private func buildPlainMergesFromClassTokens(className: String, id: String, classTokens: Tokens, basePath: String, allSpecs: ArrayList<SpecMemberInfo>, envMode: Bool, envPrefix: String): Tokens {
    let skipSet = HashSet<String>()
    for (spec in allSpecs) {
        skipSet.add(spec.memberName)
    }
    let plain = collectPlainVarsWithTypes(classTokens, skipSet)
    buildPlainFieldMerges(className, id, plain, basePath, envMode, envPrefix)
}

private func fillBindingLists(classTokens: Tokens, ms: ArrayList<String>, ks: ArrayList<String>, ts: ArrayList<String>): Unit {
    let allSpecs = collectAllSpecMembers()
    fillBindingListsWithSpecs(classTokens, ms, ks, ts, allSpecs)
}

private func fillBindingListsWithSpecs(classTokens: Tokens, ms: ArrayList<String>, ks: ArrayList<String>, ts: ArrayList<String>, allSpecs: ArrayList<SpecMemberInfo>): Unit {
    let skipSet = HashSet<String>()
    for (spec in allSpecs) {
        skipSet.add(spec.memberName)
    }
    for (spec in allSpecs) {
        ms.add(spec.memberName)
        ks.add(spec.configKey)
        ts.add(spec.fieldType)
    }
    let plain = collectPlainVarsWithTypes(classTokens, skipSet)
    for (pv in plain) {
        ms.add(pv.name)
        ks.add(pv.name)
        ts.add(pv.typeName)
    }
    if (ms.size != ks.size || ms.size != ts.size) {
        throw Exception("@config：内部错误，成员列表长度不一致")
    }
}

private func buildPostRegisterSequence(className: String, id: String, classTokens: Tokens, allSpecs: ArrayList<SpecMemberInfo>, envMode: Bool, envPrefix: String): Tokens {
    let ms = ArrayList<String>()
    let ks = ArrayList<String>()
    let ts = ArrayList<String>()
    fillBindingListsWithSpecs(classTokens, ms, ks, ts, allSpecs)
    var body = Tokens()
    let classNameLit = Token(TokenKind.STRING_LITERAL, className)
    let idLit = Token(TokenKind.STRING_LITERAL, id)
    if (ms.size > 0) {
        body = quote(
            installYamlCryptoPersistHandler()
        )
        if (envMode) {
            // 环境变量源模式：跳过文件加载，直接从环境变量读取
            body = body + quote(
                registryLoadFromEnv($classNameLit, $idLit)
            )
        } else {
            body = body + quote(
                registryLoadMainFileIntoFieldValues($classNameLit, $idLit)
            )
        }
    }
    body = body + quote(
        let __cfgInst = $(Token(TokenKind.IDENTIFIER, className))()
    )
    if (envMode) {
        // env 模式：先同步默认值到注册表，再从环境变量覆盖，然后应用到实例，不创建文件
        body = body + quote(
            Config.addInstance($classNameLit, $idLit, __cfgInst)
            __cfgInst.syncInstanceToRegistry()
            registryLoadFromEnv($classNameLit, $idLit)
            __cfgInst.applyRegistryToInstance()
            Config.dispatchLoaded($classNameLit, $idLit)
        )
    } else {
        body = body + quote(
            Config.addInstance($classNameLit, $idLit, __cfgInst)
            __cfgInst.applyRegistryToInstance()
            if (!Config.mainFileExists($classNameLit, $idLit)) {
                __cfgInst.syncInstanceToRegistry()
                Config.save($classNameLit, $idLit)
            } else if (!Config.hasAnyFieldValue($classNameLit, $idLit)) {
                __cfgInst.syncInstanceToRegistry()
            }
            Config.dispatchLoaded($classNameLit, $idLit)
        )
    }
    body
}

private func buildExtendBlock(className: String, id: String, classTokens: Tokens, allSpecs: ArrayList<SpecMemberInfo>): Tokens {
    let ms = ArrayList<String>()
    let ks = ArrayList<String>()
    let ts = ArrayList<String>()
    fillBindingListsWithSpecs(classTokens, ms, ks, ts, allSpecs)
    let applyFn = buildApplyRegistryToInstanceMethod(className, id, ms, ks, ts)
    let syncSilentFn = buildSyncInstanceToRegistryMethod(className, id, ms, ks, ts)
    let syncFn = buildSyncMethod(className, id, ms, ks, ts)
    let syncFieldFn = buildSyncFieldMethod(className, id, ms, ks, ts)
    let storeFn = quote(
        public static func storeField(fieldKey: String, value: String): Unit {
            Config.putFieldString(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                fieldKey,
                value
            )
        }
    )
    let removeFn = quote(
        public static func removeField(fieldKey: String): Bool {
            Config.removeField(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                fieldKey
            )
        }
    )
    let refFn = quote(
        public static func ref(): ConfigRef<$(Token(TokenKind.IDENTIFIER, className))> {
            let __rawInst = Config.get($(Token(TokenKind.STRING_LITERAL, className)), $(Token(TokenKind.STRING_LITERAL, id)))
            match (__rawInst as $(Token(TokenKind.IDENTIFIER, className))) {
                case Some(typed) =>
                    typed.applyRegistryToInstance()
                    ConfigRef<$(Token(TokenKind.IDENTIFIER, className))>(typed, $(Token(TokenKind.STRING_LITERAL, className)), $(Token(TokenKind.STRING_LITERAL, id)))
                case None => throw ConfigException("TYPE_ERROR", "配置实例类型不匹配")
            }
        }
    )
    let validateFn = quote(
        public static func validateField(fieldKey: String): Bool {
            Config.validateField($(Token(TokenKind.STRING_LITERAL, className)), $(Token(TokenKind.STRING_LITERAL, id)), fieldKey)
        }
    )
    let clsTok = Token(TokenKind.IDENTIFIER, className)
    let extKw = Token(TokenKind.IDENTIFIER, "extend")
    let clsLit = Token(TokenKind.STRING_LITERAL, className)
    let idLit = Token(TokenKind.STRING_LITERAL, id)
    let indexGetFn = quote(
        public func getField(key: String): String {
            Config.fieldAsString($clsLit, $idLit, key)
        }
    )
    let indexSetFn = quote(
        public func setField(key: String, value: String): Unit {
            Config.putFieldString($clsLit, $idLit, key, value)
        }
    )
    quote(
        $extKw $clsTok {
            $applyFn
            $syncSilentFn
            $syncFn
            $syncFieldFn
            $storeFn
            $removeFn
            $refFn
            $validateFn
            $indexGetFn
            $indexSetFn
        }
    )
}

private func buildListenerClassDefs(className: String, id: String, listenerSpecs: ArrayList<ListenerSpecInfo>): Tokens {
    if (listenerSpecs.size == 0) {
        return Tokens()
    }
    var classDefs = Tokens()
    for (spec in listenerSpecs) {
        let eventType = spec.eventType
        let methodName = spec.methodName
        let fieldFilter = spec.fieldFilter
        let fieldCheck = if (fieldFilter.size > 0 && fieldFilter != "*") {
            quote(
                if (field != $(Token(TokenKind.STRING_LITERAL, fieldFilter))) {
                    return
                }
            )
        } else {
            Tokens()
        }
        let listenerClassName = "__CfgLis_${className}_${methodName}"
        let listenerClassTok = Token(TokenKind.IDENTIFIER, listenerClassName)
        let listenerClassNameLit = Token(TokenKind.STRING_LITERAL, listenerClassName)
        let methodNameTok = Token(TokenKind.IDENTIFIER, methodName)
        let clsNameTok = Token(TokenKind.IDENTIFIER, className)
        let clsLitTok = Token(TokenKind.STRING_LITERAL, className)
        let idLitTok = Token(TokenKind.STRING_LITERAL, id)
        match (eventType) {
            case "change" | "CHANGE" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {
                            $fieldCheck
                            try {
                                let __raw = Config.get($clsLitTok, $idLitTok)
                                match (__raw as $clsNameTok) {
                                    case Some(__inst) => __inst.$methodNameTok(field, oldValue, newValue)
                                    case None => ()
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        }
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {}
                        public func onReloaded(): Unit {}
                        public func onSaved(): Unit {}
                        public func onError(error: ConfigException): Unit {}
                        public func onValidationError(field: String, message: String): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case "loaded" | "LOADED" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {
                            match (instanceRef.get() as $clsNameTok) {
                                case Some(inst) => inst.$methodNameTok(instanceRef)
                                case None => ()
                            }
                        }
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {}
                        public func onReloaded(): Unit {}
                        public func onSaved(): Unit {}
                        public func onError(error: ConfigException): Unit {}
                        public func onValidationError(field: String, message: String): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case "saved" | "SAVED" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onSaved(): Unit {
                            try {
                                let __raw = Config.get($clsLitTok, $idLitTok)
                                match (__raw as $clsNameTok) {
                                    case Some(__inst) => __inst.$methodNameTok()
                                    case None => ()
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        }
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {}
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {}
                        public func onReloaded(): Unit {}
                        public func onError(error: ConfigException): Unit {}
                        public func onValidationError(field: String, message: String): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case "reloaded" | "RELOADED" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onReloaded(): Unit {
                            try {
                                let __raw = Config.get($clsLitTok, $idLitTok)
                                match (__raw as $clsNameTok) {
                                    case Some(__inst) => __inst.$methodNameTok()
                                    case None => ()
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        }
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {}
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {}
                        public func onSaved(): Unit {}
                        public func onError(error: ConfigException): Unit {}
                        public func onValidationError(field: String, message: String): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case "error" | "ERROR" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onError(error: ConfigException): Unit {
                            try {
                                let __raw = Config.get($clsLitTok, $idLitTok)
                                match (__raw as $clsNameTok) {
                                    case Some(__inst) => __inst.$methodNameTok(error)
                                    case None => ()
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        }
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {}
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {}
                        public func onReloaded(): Unit {}
                        public func onSaved(): Unit {}
                        public func onValidationError(field: String, message: String): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case "validation_error" | "VALIDATION_ERROR" =>
                let cls = quote(
                    private class $listenerClassTok <: BaseConfigListener {
                        public func onValidationError(field: String, message: String): Unit {
                            $fieldCheck
                            try {
                                let __raw = Config.get($clsLitTok, $idLitTok)
                                match (__raw as $clsNameTok) {
                                    case Some(__inst) => __inst.$methodNameTok(field, message)
                                    case None => ()
                                }
                            } catch (_: Exception) {
                                ()
                            }
                        }
                        public func onLoaded(instanceRef: ConfigRef<Any>): Unit {}
                        public func onChanged(field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {}
                        public func onReloaded(): Unit {}
                        public func onSaved(): Unit {}
                        public func onError(error: ConfigException): Unit {}
                        public func getId(): String { $listenerClassNameLit }
                    }
                )
                classDefs = classDefs + cls + Token(TokenKind.NL)
            case _ =>
                diagReport(DiagReportLevel.ERROR, Tokens(), "@${spec.eventType}：未知的事件类型", "支持: onChange, onLoaded, onSaved, onReloaded, onError, onValidationError")
        }
    }
    classDefs
}

private func buildListenerRegBlock(className: String, id: String, listenerSpecs: ArrayList<ListenerSpecInfo>): Tokens {
    if (listenerSpecs.size == 0) {
        return Tokens()
    }
    var regStmts = Tokens()
    for (spec in listenerSpecs) {
        let eventType = spec.eventType
        let methodName = spec.methodName
        let listenerClassName = "__CfgLis_${className}_${methodName}"
        let listenerClassTok = Token(TokenKind.IDENTIFIER, listenerClassName)
        let clsLitTok = Token(TokenKind.STRING_LITERAL, className)
        let idLitTok = Token(TokenKind.STRING_LITERAL, id)
        let stmt = quote(
            Config.on($clsLitTok, $idLitTok, $listenerClassTok())
        )
        regStmts = regStmts + stmt + Token(TokenKind.NL)
    }
    regStmts
}

private func buildApplyRegistryToInstanceMethod(
    className: String,
    id: String,
    ms: ArrayList<String>,
    ks: ArrayList<String>,
    ts: ArrayList<String>
): Tokens {
    var stmts = Tokens()
    var i: Int64 = 0
    while (i < ms.size) {
        let mn = ms[i]
        let ck = ks[i]
        let fieldType = ts[i]
        let assign = buildTypedAssign(className, id, mn, ck, fieldType)
        stmts = stmts + assign + Token(TokenKind.NL)
        i = i + 1
    }
    quote(
        public func applyRegistryToInstance(): Unit {
            $stmts
        }
    )
}

private func buildTypedAssign(className: String, id: String, memberName: String, configKey: String, fieldType: String): Tokens {
    match (fieldType) {
        case "Int64" | "Int" =>
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) =>
                        match (__dv.toInt()) {
                            case Some(__v) => this.$(Token(TokenKind.IDENTIFIER, memberName)) = __v
                            case None => ()
                        }
                    case None => ()
                }
            )
        case "Bool" =>
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) =>
                        match (__dv.toBool()) {
                            case Some(__v) => this.$(Token(TokenKind.IDENTIFIER, memberName)) = __v
                            case None => ()
                        }
                    case None => ()
                }
            )
        case "Float64" | "Float" =>
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) =>
                        match (__dv.toFloat()) {
                            case Some(__v) => this.$(Token(TokenKind.IDENTIFIER, memberName)) = __v
                            case None => ()
                        }
                    case None => ()
                }
            )
        case "String" =>
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) => this.$(Token(TokenKind.IDENTIFIER, memberName)) = __dv.toString()
                    case None => ()
                }
            )
        case _ where fieldType == "Array<String>" =>
            quote(
                this.$(Token(TokenKind.IDENTIFIER, memberName)) = Config.fieldAsArrayString(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )
            )
        case _ where fieldType == "HashMap<String,String>" =>
            quote(
                this.$(Token(TokenKind.IDENTIFIER, memberName)) = Config.fieldAsMapString(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )
            )
        case _ where fieldType.startsWith("Array<") || fieldType.startsWith("Array ") =>
            let (elemType, elemTypeSimple) = extractNestedElementType(fieldType)
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) =>
                        match (__dv.toJsonString()) {
                            case Some(__jsonStr) =>
                                try {
                                    let __jv = JsonValue.fromStr(__jsonStr)
                                    let __arr = __jv.asArray().getItems()
                                    let __result = ArrayList<$(Token(TokenKind.IDENTIFIER, elemType))>()
                                    for (__item in __arr) {
                                        let __obj = __item.asObject()
                                        __result.add($(Token(TokenKind.IDENTIFIER, elemTypeSimple)).fromJson(__obj))
                                    }
                                    this.$(Token(TokenKind.IDENTIFIER, memberName)) = __result.toArray()
                                } catch (_: Exception) {
                                    ()
                                }
                            case None => ()
                        }
                    case None => ()
                }
            )
        case _ where fieldType.startsWith("HashMap<") || fieldType.startsWith("HashMap ") =>
            let (keyType, valType, valTypeSimple) = extractNestedMapValueType(fieldType)
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) =>
                        match (__dv.toJsonString()) {
                            case Some(__jsonStr) =>
                                try {
                                    let __jv = JsonValue.fromStr(__jsonStr)
                                    let __obj = __jv.asObject()
                                    let __result = HashMap<$(Token(TokenKind.IDENTIFIER, keyType)), $(Token(TokenKind.IDENTIFIER, valType))>()
                                    for ((__k, __v) in __obj.getFields()) {
                                        let __mapVal = __v.asObject()
                                        __result[__k] = $(Token(TokenKind.IDENTIFIER, valTypeSimple)).fromJson(__mapVal)
                                    }
                                    this.$(Token(TokenKind.IDENTIFIER, memberName)) = __result
                                } catch (_: Exception) {
                                    ()
                                }
                            case None => ()
                        }
                    case None => ()
                }
            )
        case _ =>
            quote(
                match (Config.getField(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, configKey))
                )) {
                    case Some(__dv) => this.$(Token(TokenKind.IDENTIFIER, memberName)) = __dv.toString()
                    case None => ()
                }
            )
    }
}

private func extractNestedElementType(fieldType: String): (String, String) {
    let startIdx = fieldType.indexOf("<").getOrThrow()
    let endIdx = fieldType.lastIndexOf(">").getOrThrow()
    let elemType = fieldType[(startIdx + 1)..endIdx].trimAscii()
    (elemType, elemType)
}

private func extractNestedMapValueType(fieldType: String): (String, String, String) {
    let startIdx = fieldType.indexOf("<").getOrThrow()
    let endIdx = fieldType.lastIndexOf(">").getOrThrow()
    let inner = fieldType[(startIdx + 1)..endIdx].trimAscii()
    let commaIdx = inner.indexOf(",").getOrThrow()
    let keyType = inner[0..commaIdx].trimAscii()
    let valType = inner[(commaIdx + 1)..inner.size].trimAscii()
    (keyType, valType, valType)
}

private func buildSyncInstanceToRegistryMethod(
    className: String,
    id: String,
    ms: ArrayList<String>,
    ks: ArrayList<String>,
    ts: ArrayList<String>
): Tokens {
    var stmts = Tokens()
    var i: Int64 = 0
    while (i < ms.size) {
        let mn = ms[i]
        let ck = ks[i]
        let fieldType = ts[i]
        let dvStmt = buildTypedDVConversion(fieldType, mn)
        let stmt = quote(
            Config.setSilent(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                $(Token(TokenKind.STRING_LITERAL, ck)),
                $dvStmt
            )
        )
        stmts = stmts + stmt + Token(TokenKind.NL)
        i = i + 1
    }
    quote(
        public func syncInstanceToRegistry(): Unit {
            $stmts
        }
    )
}

private func buildTypedDVConversion(fieldType: String, memberName: String): Tokens {
    match (fieldType) {
        case "Int64" | "Int" =>
            quote(DVInt(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case "Bool" =>
            quote(DVBool(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case "Float64" | "Float" =>
            quote(DVFloat(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case "String" =>
            quote(DVString(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case _ where fieldType == "Array<String>" =>
            quote(Config.arrayToDVArray(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case _ where fieldType == "HashMap<String,String>" =>
            quote(Config.mapToDVMap(this.$(Token(TokenKind.IDENTIFIER, memberName))))
        case _ where fieldType.startsWith("Array<") || fieldType.startsWith("Array ") =>
            let (elemType, _) = extractNestedElementType(fieldType)
            quote(
                Config.nestedArrayToDV(
                    this.$(Token(TokenKind.IDENTIFIER, memberName)),
                    $(Token(TokenKind.STRING_LITERAL, elemType))
                )
            )
        case _ where fieldType.startsWith("HashMap<") || fieldType.startsWith("HashMap ") =>
            let (keyType, valType, _) = extractNestedMapValueType(fieldType)
            quote(
                Config.nestedMapToDV(
                    this.$(Token(TokenKind.IDENTIFIER, memberName)),
                    $(Token(TokenKind.STRING_LITERAL, keyType)),
                    $(Token(TokenKind.STRING_LITERAL, valType))
                )
            )
        case _ =>
            quote(DVString(this.$(Token(TokenKind.IDENTIFIER, memberName)).toString()))
    }
}

private func buildSyncMethod(
    className: String,
    id: String,
    ms: ArrayList<String>,
    ks: ArrayList<String>,
    ts: ArrayList<String>
): Tokens {
    var stmts = Tokens()
    var i: Int64 = 0
    while (i < ms.size) {
        let mn = ms[i]
        let ck = ks[i]
        let fieldType = ts[i]
        let dvStmt = buildTypedDVConversion(fieldType, mn)
        let stmt = quote(
            Config.set(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                $(Token(TokenKind.STRING_LITERAL, ck)),
                $dvStmt
            )
        )
        stmts = stmts + stmt + Token(TokenKind.NL)
        i = i + 1
    }
    quote(
        public func sync(): Unit {
            $stmts
        }
    )
}

private func buildSyncFieldMethod(
    className: String,
    id: String,
    ms: ArrayList<String>,
    ks: ArrayList<String>,
    ts: ArrayList<String>
): Tokens {
    var cases = Tokens()
    var i: Int64 = 0
    while (i < ms.size) {
        let mn = ms[i]
        let ck = ks[i]
        let fieldType = ts[i]
        let dvStmt = buildTypedDVConversion(fieldType, mn)
        let caseStmt = quote(
            case $(Token(TokenKind.STRING_LITERAL, mn)) =>
                Config.set(
                    $(Token(TokenKind.STRING_LITERAL, className)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    $(Token(TokenKind.STRING_LITERAL, ck)),
                    $dvStmt
                )
        )
        cases = cases + caseStmt + Token(TokenKind.NL)
        i = i + 1
    }
    quote(
        public func syncField(field: String): Unit {
            match (field) {
                $cases
                case _ => ()
            }
        }
    )
}

private func extractClassNameFromAnnotatedClassTokens(input: Tokens): String {
    let decl = parseDecl(input)
    match (decl as ClassDecl) {
        case Some(cls) => cls.identifier.value
        case None =>
            match (decl as StructDecl) {
                case Some(st) => st.identifier.value
                case None => throw Exception("@config：仅可用于 class 或 struct 声明")
            }
    }
}

private func buildMergeFieldInfosFromChildMessages(className: String, classIdDefault: String, basePath: String, envMode: Bool, envPrefix: String): Tokens {
    var block = Tokens()
    let allSpecs = collectAllSpecMembers()
    for (spec in allSpecs) {
        let resolvedPath = if (basePath.size > 0) {
            if (spec.path.size > 0) { basePath + "." + spec.path } else { basePath }
        } else {
            spec.path
        }
        // env 模式下，未显式指定 env 的字段自动推导环境变量名
        let effectiveEnv = if (envMode && spec.env.size == 0) {
            camelToUpperSnake(spec.memberName, envPrefix)
        } else {
            spec.env
        }
        let line = spec.flavor + SPEC_SEP + classIdDefault + SPEC_SEP + spec.memberName + SPEC_SEP +
            spec.configKey + SPEC_SEP + resolvedPath + SPEC_SEP + spec.fieldType + SPEC_SEP +
            spec.defaultValue + SPEC_SEP + spec.isLazy.toString() + SPEC_SEP + spec.sensitive.toString() +
            SPEC_SEP + spec.verifyPattern + SPEC_SEP + spec.cryptoAlgorithm + SPEC_SEP + spec.cryptoKeyId +
            SPEC_SEP + effectiveEnv
        let stmt = quoteMergeFromSpecLine(className, classIdDefault, line, basePath)
        block = block + stmt + Token(TokenKind.NL)
    }
    block
}

private func quoteMergeFromSpecLine(className: String, classIdDefault: String, line: String, basePath: String): Tokens {
    let parts = line.split(SPEC_SEP, removeEmpty: false)
    if (parts.size < 12) {
        throw Exception("cfgFieldSpec 字段不足，请检查成员宏展开: ${parts.size}")
    }
    let flavor = parts[0]
    var instId = parts[1]
    if (instId.size == 0) {
        instId = classIdDefault
    }
    let memberName = parts[2]
    let configKey = parts[3]
    let rawPath = parts[4]
    let resolvedPath = if (basePath.size > 0) {
        if (rawPath.size > 0) { basePath + "." + rawPath } else { basePath }
    } else {
        rawPath
    }
    let fieldTypeName = parts[5]
    let defTok = parts[6]
    let isLazy = parts[7] == "true"
    let sensitive = parts[8] == "true"
    let verifyPattern = parts[9]
    let cryptoAlgorithm = parts[10]
    let cryptoKeyId = parts[11]
    let envVar = if (parts.size >= 13) { parts[12] } else { "" }

    let defaultStr: ?String = if (defTok == "__NONE__") {
        None
    } else {
        Some(defTok)
    }

    if (flavor == "A" || flavor == "E" || flavor == "V") {
        ()
    } else {
        throw Exception("未知字段宏种类: ${flavor}")
    }

    quoteMergeFieldInfosFull(
        className,
        instId,
        memberName,
        configKey,
        resolvedPath,
        fieldTypeName,
        defaultStr,
        isLazy,
        sensitive,
        verifyPattern,
        cryptoAlgorithm,
        cryptoKeyId,
        envVar
    )
}

private func serializeFieldSpec(
    flavorLetter: String,
    idInst: String,
    memberName: String,
    configKey: String,
    path: String,
    fieldTypeName: String,
    defaultStr: ?String,
    isLazy: Bool,
    sensitive: Bool,
    verifyPattern: String,
    cryptoAlgorithm: String,
    cryptoKeyId: String,
    envVar: String
): String {
    let defPart = match (defaultStr) {
        case Some(dv) => dv
        case None => "__NONE__"
    }
    let lazyS = if (isLazy) {
        "true"
    } else {
        "false"
    }
    let sensS = if (sensitive) {
        "true"
    } else {
        "false"
    }
    flavorLetter + SPEC_SEP + idInst + SPEC_SEP + memberName + SPEC_SEP + configKey + SPEC_SEP + path + SPEC_SEP +
        fieldTypeName + SPEC_SEP + defPart + SPEC_SEP + lazyS + SPEC_SEP + sensS + SPEC_SEP + verifyPattern + SPEC_SEP +
        cryptoAlgorithm + SPEC_SEP + cryptoKeyId + SPEC_SEP + envVar
}

private enum MemberFieldFlavor {
    | Alias
    | Encrypt
    | Verify
}

private func expandMemberFieldMacro(attrTokens: Tokens, input: Tokens, flavor: MemberFieldFlavor): Tokens {
    assertParentContext("config")
    let attrs = parseAttrs(attrTokens)
    let positionalStr = parseFirstStringLiteral(attrTokens)
    let decl = parseDecl(input)
    let varDecl = match (decl as VarDecl) {
        case Some(v) => v
        case None => throw Exception("该宏仅可用于 var/let 成员声明")
    }
    let memberName = varDecl.identifier.value
    let declaredTypeName = extractTypeNameFromVarDecl(varDecl)
    let idInst = match (attrs.get("id")) {
        case Some(v) => v
        case None => ""
    }

    var configKey: String = ""
    var path: String = ""
    var fieldTypeName = match (attrs.get("fieldTypeName")) {
        case Some(v) => v
        case None => declaredTypeName
    }
    // isLazy 已移除：配置字段在类初始化时即时求值，惰性语义无意义，FieldInfo.isLazy 作为保留字段恒为 false。
    let isLazy = false
    var sensitive = boolFromAttr(attrs, "sensitive", false)
    // defaultValue 已移除：默认值由结构体字段初始化器原生提供（如 var port: Int64 = 8080），不再经宏属性注入。
    let defaultStr: ?String = None
    var verifyPattern = ""
    var cryptoAlgorithm = ""
    var cryptoKeyId = ""
    var envVar = ""

    var flavorLetter: String = "A"
    match (flavor) {
        case Alias =>
            flavorLetter = "A"
            configKey = match (positionalStr) {
                case Some(k) => k
                case None =>
                    match (attrs.get("key")) {
                        case Some(k) => k
                        case None => memberName
                    }
            }
            path = match (attrs.get("path")) {
                case Some(p) => p
                case None => configKey
            }
            envVar = match (attrs.get("env")) {
                case Some(e) => e
                case None => ""
            }
        case Encrypt =>
            flavorLetter = "E"
            configKey = match (attrs.get("key")) {
                case Some(k) => k
                case None => memberName
            }
            path = match (attrs.get("path")) {
                case Some(p) => p
                case None => configKey
            }
            sensitive = true
            cryptoAlgorithm = match (positionalStr) {
                case Some(alg) => alg
                case None =>
                    match (attrs.get("algorithm")) {
                        case Some(a) => a
                        case None => "sym:enc:v1"
                    }
            }
            match (attrs.get("with")) {
                case Some(w) => cryptoAlgorithm = w
                case None => ()
            }
            cryptoKeyId = match (attrs.get("keyId")) {
                case Some(v) => v
                case None => ""
            }
        case Verify =>
            flavorLetter = "V"
            configKey = match (attrs.get("key")) {
                case Some(k) => k
                case None => memberName
            }
            path = match (attrs.get("path")) {
                case Some(p) => p
                case None => configKey
            }
            verifyPattern = match (positionalStr) {
                case Some(p) => p
                case None =>
                    match (attrs.get("pattern")) {
                        case Some(pat) => pat
                        case None => throw Exception("@verify 须提供正则字符串作为位置参数，如 @verify(r\"\\d+\")")
                    }
            }
    }

    let spec = serializeFieldSpec(
        flavorLetter,
        idInst,
        memberName,
        configKey,
        path,
        fieldTypeName,
        defaultStr,
        isLazy,
        sensitive,
        verifyPattern,
        cryptoAlgorithm,
        cryptoKeyId,
        envVar
    )
    setItem(SPEC_KEY, spec)
    input
}

private enum ListenerEventType {
    | Change
    | Loaded
    | Saved
    | Reloaded
    | Error
    | ValidationError
}

private func expandListenerMacro(attrTokens: Tokens, input: Tokens, eventType: ListenerEventType): Tokens {
    assertParentContext("config")
    let attrs = parseAttrs(attrTokens)
    let positionalStr = parseFirstStringLiteral(attrTokens)

    let methodName = match (attrs.get("method")) {
        case Some(v) => v
        case None =>
            match (positionalStr) {
                case Some(m) => m
                case None => throw Exception("@onChange/@onLoaded 等须提供方法名，如 @onChange(methodName) 或 method=\"onMyChange\"")
            }
    }
    let fieldFilter = match (attrs.get("field")) {
        case Some(v) => v
        case None => "*"
    }

    let eventTypeName = match (eventType) {
        case Change => "change"
        case Loaded => "loaded"
        case Saved => "saved"
        case Reloaded => "reloaded"
        case Error => "error"
        case ValidationError => "validation_error"
    }

    let spec = eventTypeName + SPEC_SEP + methodName + SPEC_SEP + fieldFilter
    setItem(LISTENER_KEY, spec)
    input
}

private func expandAnnotatedConfigClass(attrTokens: Tokens, input: Tokens): Tokens {
    let attrs = parseAttrs(attrTokens)
    let className = extractClassNameFromAnnotatedClassTokens(input)

    let file = match (attrs.get("file")) {
        case Some(v) => v
        case None => match (attrs.get("files")) {
            case Some(f) => f.split(",")[0].trimAscii()
            case None => "config.yaml"
        }
    }
    let files = match (attrs.get("files")) {
        case Some(v) => v
        case None => ""
    }
    let id = match (attrs.get("id")) {
        case Some(v) => v
        case None => "default"
    }
    let basePath = match (attrs.get("basePath")) {
        case Some(v) => v
        case None => ""
    }
    let autosave = boolFromAttr(attrs, "autosave", false)
    let autosync = boolFromAttr(attrs, "autosync", true)
    let validate = boolFromAttr(attrs, "validate", false)
    let stream = boolFromAttr(attrs, "stream", false)
    let bindRegistry = boolFromAttr(attrs, "bindRegistry", true)
    let envMode = boolFromAttr(attrs, "env", false)
    let envPrefix = match (attrs.get("prefix")) {
        case Some(v) => v
        case None => ""
    }

    let registerCall = if (files.size > 0) {
        let filesArray = parseFilesArrayFromTokens(attrTokens, "files")
        quote(
            Config.registerWithFilesAndOptions(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, file)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                $(Token(TokenKind.STRING_LITERAL, basePath)),
                $filesArray,
                $(autosave),
                $(autosync),
                $(validate),
                $(stream)
            )
        )
    } else {
        quote(
            Config.registerWithOptions(
                $(Token(TokenKind.STRING_LITERAL, className)),
                $(Token(TokenKind.STRING_LITERAL, file)),
                $(Token(TokenKind.STRING_LITERAL, id)),
                $(Token(TokenKind.STRING_LITERAL, basePath)),
                $(autosave),
                $(autosync),
                $(validate),
                $(stream)
            )
        )
    }

    let mergeChild = buildMergeFieldInfosFromChildMessages(className, id, basePath, envMode, envPrefix)
    if (!bindRegistry) {
        return wrapConfigExpansionWithStaticInit(className, registerCall, mergeChild, Tokens(), Tokens(), Tokens(), Tokens(), input)
    }
    let allSpecs = collectAllSpecMembers()
    let allListeners = collectAllListenerSpecs()
    let plainMerge = buildPlainMergesFromClassTokens(className, id, input, basePath, allSpecs, envMode, envPrefix)
    let mergeBlock = mergeChild + plainMerge
    let postReg = buildPostRegisterSequence(className, id, input, allSpecs, envMode, envPrefix)
    let listenerReg = buildListenerRegBlock(className, id, allListeners)
    let listenerDefs = buildListenerClassDefs(className, id, allListeners)
    let ext = buildExtendBlock(className, id, input, allSpecs)
    wrapConfigExpansionWithStaticInit(className, registerCall, mergeBlock, postReg, ext, listenerReg, listenerDefs, input)
}

private func parseFilesArrayFromTokens(attrTokens: Tokens, attrName: String): Tokens {
    var foundAttr = false
    var inArray = false
    var elements = Tokens()
    var priority: Int64 = 10
    var isFirst = true
    var i: Int64 = 0
    while (i < attrTokens.size) {
        let tok = attrTokens[i]
        if (tok.kind == TokenKind.IDENTIFIER && tok.value == attrName) {
            foundAttr = true
        } else if (foundAttr && tok.kind == TokenKind.LSQUARE) {
            inArray = true
        } else if (inArray && tok.kind == TokenKind.STRING_LITERAL) {
            let file = tok.value
            let fmt = if (file.endsWith(".json")) {
                "JSON"
            } else if (file.endsWith(".yaml") || file.endsWith(".yml")) {
                "YAML"
            } else if (file.endsWith(".ini")) {
                "INI"
            } else if (file.endsWith(".toml")) {
                "TOML"
            } else if (file.endsWith(".xml")) {
                "XML"
            } else if (file.endsWith(".env")) {
                "ENV"
            } else if (file.endsWith(".conf")) {
                "CONF"
            } else {
                "YAML"
            }
            let fmtTok = Token(TokenKind.IDENTIFIER, fmt)
            let fileTok = Token(TokenKind.STRING_LITERAL, file)
            let currentPriority = priority
            let firstExistsTok = Token(TokenKind.IDENTIFIER, if (isFirst) { "true" } else { "false" })
            priority = priority + 10
            isFirst = false
            let element = quote(
                ConfigSource($fmtTok, $fileTok, $(Token(TokenKind.STRING_LITERAL, "")), $(Token(TokenKind.INTEGER_LITERAL, currentPriority.toString())), $firstExistsTok)
            )
            elements = elements + element + Token(TokenKind.COMMA) + Token(TokenKind.NL)
        } else if (inArray && tok.kind == TokenKind.RSQUARE) {
            break
        } else if (foundAttr && !inArray && tok.kind == TokenKind.COMMA) {
            foundAttr = false
        }
        i += 1
    }
    if (elements.size > 0 && elements[elements.size - 1].kind == TokenKind.COMMA) {
        elements = elements[0..(elements.size - 1)]
    }
    let arrTok = Token(TokenKind.IDENTIFIER, "Array")
    quote(
        $(arrTok)<ConfigSource>([$elements])
    )
}

public macro config(input: Tokens): Tokens {
    expandAnnotatedConfigClass(Tokens(), input)
}

public macro config(attrTokens: Tokens, input: Tokens): Tokens {
    expandAnnotatedConfigClass(attrTokens, input)
}

public macro key(attrTokens: Tokens, input: Tokens): Tokens {
    expandMemberFieldMacro(attrTokens, input, MemberFieldFlavor.Alias)
}

public macro key(input: Tokens): Tokens {
    expandMemberFieldMacro(Tokens(), input, MemberFieldFlavor.Alias)
}

public macro encrypt(attrTokens: Tokens, input: Tokens): Tokens {
    expandMemberFieldMacro(attrTokens, input, MemberFieldFlavor.Encrypt)
}

public macro encrypt(input: Tokens): Tokens {
    expandMemberFieldMacro(Tokens(), input, MemberFieldFlavor.Encrypt)
}

public macro verify(attrTokens: Tokens, input: Tokens): Tokens {
    expandMemberFieldMacro(attrTokens, input, MemberFieldFlavor.Verify)
}

public macro verify(input: Tokens): Tokens {
    expandMemberFieldMacro(Tokens(), input, MemberFieldFlavor.Verify)
}

public macro onChange(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.Change)
}

public macro onChange(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.Change)
}

public macro onLoaded(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.Loaded)
}

public macro onLoaded(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.Loaded)
}

public macro onSaved(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.Saved)
}

public macro onSaved(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.Saved)
}

public macro onReloaded(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.Reloaded)
}

public macro onReloaded(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.Reloaded)
}

public macro onError(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.Error)
}

public macro onError(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.Error)
}

public macro onValidationError(attrTokens: Tokens, input: Tokens): Tokens {
    expandListenerMacro(attrTokens, input, ListenerEventType.ValidationError)
}

public macro onValidationError(input: Tokens): Tokens {
    expandListenerMacro(Tokens(), input, ListenerEventType.ValidationError)
}

private func boolFromAttr(map: HashMap<String, String>, key: String, default: Bool): Bool {
    match (map.get(key)) {
        case Some(v) => v == "true"
        case None => default
    }
}

private func parseFirstStringLiteral(tokens: Tokens): ?String {
    var i: Int64 = 0
    while (i < tokens.size) {
        if (tokens[i].kind == TokenKind.STRING_LITERAL) {
            // 跳过命名属性的值：如 key = "xxx" 中的 "xxx" 不是位置参数
            if (i >= 2) {
                let prev = tokens[i - 1]
                if (prev.kind == TokenKind.ASSIGN || prev.kind == TokenKind.COLON) {
                    i = i + 1
                    continue
                }
            }
            return Some(tokens[i].value)
        }
        i = i + 1
    }
    None
}

private func quoteMergeFieldInfosFull(
    configType: String,
    id: String,
    memberName: String,
    configKey: String,
    path: String,
    fieldTypeName: String,
    defaultStr: ?String,
    isLazy: Bool,
    sensitive: Bool,
    verifyPattern: String,
    cryptoAlgorithm: String,
    cryptoKeyId: String,
    envVar: String
): Tokens {
    match (defaultStr) {
        case Some(dv) =>
            quote(
                Config.mergeFieldInfos(
                    $(Token(TokenKind.STRING_LITERAL, configType)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    [
                        FieldInfo(
                            $(Token(TokenKind.STRING_LITERAL, memberName)),
                            $(Token(TokenKind.STRING_LITERAL, configKey)),
                            $(Token(TokenKind.STRING_LITERAL, path)),
                            $(Token(TokenKind.STRING_LITERAL, fieldTypeName)),
                            Some(DVString($(Token(TokenKind.STRING_LITERAL, dv)))),
                            $(isLazy),
                            $(sensitive),
                            $(Token(TokenKind.STRING_LITERAL, verifyPattern)),
                            $(Token(TokenKind.STRING_LITERAL, cryptoAlgorithm)),
                            $(Token(TokenKind.STRING_LITERAL, cryptoKeyId)),
                            $(Token(TokenKind.STRING_LITERAL, envVar))
                        )
                    ]
                )
            )
        case None =>
            quote(
                Config.mergeFieldInfos(
                    $(Token(TokenKind.STRING_LITERAL, configType)),
                    $(Token(TokenKind.STRING_LITERAL, id)),
                    [
                        FieldInfo(
                            $(Token(TokenKind.STRING_LITERAL, memberName)),
                            $(Token(TokenKind.STRING_LITERAL, configKey)),
                            $(Token(TokenKind.STRING_LITERAL, path)),
                            $(Token(TokenKind.STRING_LITERAL, fieldTypeName)),
                            None,
                            $(isLazy),
                            $(sensitive),
                            $(Token(TokenKind.STRING_LITERAL, verifyPattern)),
                            $(Token(TokenKind.STRING_LITERAL, cryptoAlgorithm)),
                            $(Token(TokenKind.STRING_LITERAL, cryptoKeyId)),
                            $(Token(TokenKind.STRING_LITERAL, envVar))
                        )
                    ]
                )
            )
    }
}

private func parseAttrs(tokens: Tokens): HashMap<String, String> {
    let map = HashMap<String, String>()
    var i: Int64 = 0
    while (i < tokens.size) {
        let token = tokens[i]
        if (token.kind == TokenKind.IDENTIFIER) {
            let key = token.value
            var j = i + 1
            while (j < tokens.size && tokens[j].kind == TokenKind.NL) { j += 1 }
            if (j < tokens.size && (tokens[j].kind == TokenKind.ASSIGN || tokens[j].kind == TokenKind.COLON)) {
                j += 1
                while (j < tokens.size && (tokens[j].kind == TokenKind.NL || tokens[j].value == ",")) { j += 1 }
                if (j < tokens.size && tokens[j].kind == TokenKind.STRING_LITERAL) {
                    map.add(key, tokens[j].value)
                    i = j + 1
                } else if (j < tokens.size && (tokens[j].value == "true" || tokens[j].value == "false")) {
                    // 布尔属性：env=true, autosave=false 等
                    map.add(key, tokens[j].value)
                    i = j + 1
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        } else {
            i += 1
        }
    }
    map
}
