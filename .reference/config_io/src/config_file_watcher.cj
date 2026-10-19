package config_io

import std.collection.*
import std.sync.*
import std.time.*
import std.fs.*

public class ConfigFileWatcher {
    private let store: ConfigStore
    private let listenerManager: ListenerManager
    private let lock: Mutex = Mutex()
    private var diskLoader: ?ConfigDiskLoader = None
    private let fileWatchSig: HashMap<String, String> = HashMap()
    private let watchRunning: AtomicBool = AtomicBool(false)
    private var watchThreadStarted: Bool = false
    private let pendingReloads: ArrayList<(String, String)> = ArrayList()
    private let pendingReloadsLock: Mutex = Mutex()

    public init(store: ConfigStore, listenerManager: ListenerManager) {
        this.store = store
        this.listenerManager = listenerManager
    }

    public func setDiskLoader(loader: ConfigDiskLoader): Unit {
        synchronized(lock) {
            diskLoader = Some(loader)
        }
    }

    public func start(): Unit {
        synchronized(lock) {
            if (watchThreadStarted) {
                return
            }
            watchThreadStarted = true
        }
        watchRunning.store(true)
        spawn {
            => while (watchRunning.load()) {
                let ms = ConfigDefaults.getDefaults().watchInterval
                sleep(Duration.millisecond * ms)
                if (!watchRunning.load()) {
                    break
                }
                pollAutosyncFileChanges()
                processBatchReloads()
            }
        }
    }

    public func stop(): Unit {
        watchRunning.store(false)
    }

    private func pollAutosyncFileChanges(): Unit {
        let loaderOpt: ?ConfigDiskLoader
        synchronized(lock) {
            loaderOpt = diskLoader
        }
        match (loaderOpt) {
            case None => return
            case Some(loader) =>
                let entries = store.getAutosyncConfigs()
                for ((key, info) in entries) {
                    let sig = combinedWatchSignature(info)
                    match (fileWatchSig.get(key)) {
                        case None =>
                            synchronized(lock) {
                                fileWatchSig.add(key, sig)
                            }
                        case Some(old) =>
                            if (old != sig) {
                                synchronized(lock) {
                                    fileWatchSig.remove(key)
                                    fileWatchSig.add(key, sig)
                                }
                                let typeName = keySegmentBeforeColon(key)
                                let instId = extractId(key)
                                synchronized(pendingReloadsLock) {
                                    pendingReloads.add((typeName, instId))
                                }
                            }
                    }
                }
        }
    }

    private func processBatchReloads(): Unit {
        var reloads: Array<(String, String)>
        synchronized(pendingReloadsLock) {
            if (pendingReloads.size == 0) {
                return
            }
            reloads = pendingReloads.toArray()
            pendingReloads.clear()
        }
        
        let loaderOpt: ?ConfigDiskLoader
        synchronized(lock) {
            loaderOpt = diskLoader
        }
        match (loaderOpt) {
            case None => return
            case Some(loader) =>
                for ((typeName, instId) in reloads) {
                    try {
                        loader.loadIntoRegistry(typeName, instId)
                        listenerManager.dispatchReloaded(typeName, instId)
                    } catch (e: Exception) {
                        println("ConfigFileWatcher: 热更新配置失败 ${typeName}:${instId}: ${e.message}")
                    }
                }
        }
    }

    private func combinedWatchSignature(info: ConfigInfo): String {
        var s = fileEntrySignature(Path(info.file))
        for (src in info.sources) {
            s = s + "|" + fileEntrySignature(Path(src.file))
        }
        s
    }

    private func fileEntrySignature(path: Path): String {
        if (!exists(path)) {
            return "0:missing"
        }
        try {
            let fi = FileInfo(path)
            "${fi.size}:${fi.lastModificationTime.toString()}"
        } catch (_: Exception) {
            "0:err"
        }
    }

    private func keySegmentBeforeColon(key: String): String {
        match (key.indexOf(":")) {
            case Some(i) => key[0..i]
            case None => key
        }
    }

    private func extractId(key: String): String {
        match (key.indexOf(":")) {
            case Some(idx) => key[idx + 1..key.size]
            case None => "default"
        }
    }
}
