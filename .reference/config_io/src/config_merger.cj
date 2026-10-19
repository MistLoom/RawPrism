package config_io

import std.collection.*

public class ConfigMerger {
    private let store: ConfigStore

    public init(store: ConfigStore) {
        this.store = store
    }

    public func mergeFieldInfos(typeName: String, id: String, fields: Array<FieldInfo>): Unit {
        let info = store.getConfigInfo(typeName, id)
        let merged = mergeFieldArrays(info.fields, fields)
        let newInfo = ConfigInfo(
            info.configType,
            info.file,
            info.format,
            info.sources,
            merged,
            info.basePath,
            info.autosave,
            info.autosync,
            info.validate,
            info.stream
        )
        store.updateConfigInfo(typeName, id, newInfo)
        syncSensitiveRegistryForFields(merged)
    }

    public func mergeSources(typeName: String, id: String, sources: Array<ConfigSource>): Unit {
        let info = store.getConfigInfo(typeName, id)
        let mergedList = ArrayList<ConfigSource>()
        for (s in info.sources) {
            mergedList.add(s)
        }
        for (s in sources) {
            mergedList.add(s)
        }
        let newInfo = ConfigInfo(
            info.configType,
            info.file,
            info.format,
            mergedList.toArray(),
            info.fields,
            info.basePath,
            info.autosave,
            info.autosync,
            info.validate,
            info.stream
        )
        store.updateConfigInfo(typeName, id, newInfo)
    }

    private func mergeFieldArrays(old: Array<FieldInfo>, incoming: Array<FieldInfo>): Array<FieldInfo> {
        let map = HashMap<String, FieldInfo>()
        for (f in old) {
            map.add(f.memberName, f)
        }
        for (f in incoming) {
            match (map.get(f.memberName)) {
                case Some(prev) => map.add(f.memberName, mergeFieldInfoMerge(prev, f))
                case None => map.add(f.memberName, f)
            }
        }
        let out = ArrayList<FieldInfo>()
        for ((_, f) in map) {
            out.add(f)
        }
        out.toArray()
    }

    private func mergeFieldInfoMerge(old: FieldInfo, new_: FieldInfo): FieldInfo {
        let memberName = old.memberName
        let configKey = mergeConfigKeyPrefer(old, new_)
        let path = mergePathPrefer(old, new_, configKey)
        let fieldTypeName = if (new_.fieldTypeName != "String") {
            new_.fieldTypeName
        } else {
            old.fieldTypeName
        }
        let defaultValue = match (new_.defaultValue) {
            case Some(_) => new_.defaultValue
            case None => old.defaultValue
        }
        let isLazy = old.isLazy || new_.isLazy
        let sensitive = old.sensitive || new_.sensitive
        let verifyPattern = if (new_.verifyPattern.size > 0) {
            new_.verifyPattern
        } else {
            old.verifyPattern
        }
        let cryptoAlgorithm = if (new_.cryptoAlgorithm.size > 0) {
            new_.cryptoAlgorithm
        } else {
            old.cryptoAlgorithm
        }
        let cryptoKeyId = if (new_.cryptoKeyId.size > 0) {
            new_.cryptoKeyId
        } else {
            old.cryptoKeyId
        }
        let newEnv = if (new_.env.size > 0) {
            new_.env
        } else {
            old.env
        }
        FieldInfo(
            memberName,
            configKey,
            path,
            fieldTypeName,
            defaultValue,
            isLazy,
            sensitive,
            verifyPattern,
            cryptoAlgorithm,
            cryptoKeyId,
            newEnv
        )
    }

    private func mergeConfigKeyPrefer(old: FieldInfo, new_: FieldInfo): String {
        let newExplicit = new_.configKey != new_.memberName
        let oldExplicit = old.configKey != old.memberName
        if (newExplicit) {
            return new_.configKey
        }
        if (oldExplicit) {
            return old.configKey
        }
        new_.memberName
    }

    private func mergePathPrefer(old: FieldInfo, new_: FieldInfo, mergedConfigKey: String): String {
        let newExplicit = new_.path != new_.memberName
        let oldExplicit = old.path != old.memberName
        if (newExplicit) {
            return new_.path
        }
        if (oldExplicit) {
            return old.path
        }
        mergedConfigKey
    }

    private func syncSensitiveRegistryForFields(fields: Array<FieldInfo>): Unit {
        for (f in fields) {
            if (f.sensitive || f.cryptoAlgorithm.size > 0) {
                SensitiveFieldRegistry.register(f.configKey)
            }
        }
    }
}
