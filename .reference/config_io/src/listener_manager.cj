package config_io

import std.collection.*
import std.sync.*

public class ListenerManager {
    private let lock: Mutex = Mutex()
    private let listeners: HashMap<String, ArrayList<BaseConfigListener>> = HashMap()
    private let store: ConfigStore

    public init(store: ConfigStore) {
        this.store = store
    }

    public func addListener(typeName: String, id: String, listener: BaseConfigListener): BaseConfigListener {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (listeners.get(key)) {
                case Some(lst) =>
                    lst.add(listener)
                case None =>
                    let lst = ArrayList<BaseConfigListener>()
                    lst.add(listener)
                    listeners.add(key, lst)
            }
        }

        let instOpt = store.getInstanceOpt(typeName, id)
        match (instOpt) {
            case Some(inst) =>
                let ref = ConfigRef<Any>(inst)
                listener.onLoaded(ref)
            case None => ()
        }

        listener
    }

    public func removeListener(typeName: String, id: String, listener: BaseConfigListener): Unit {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (listeners.get(key)) {
                case Some(lst) =>
                    let listenerId = listener.getId()
                    var foundIndex = -1
                    for (i in 0..lst.size) {
                        if (lst[i].getId() == listenerId) {
                            foundIndex = i
                            break
                        }
                    }
                    if (foundIndex >= 0) {
                        lst.remove(at: foundIndex)
                    }
                case None => ()
            }
        }
    }

    public func dispatchLoaded(typeName: String, id: String): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                let instOpt = store.getInstanceOpt(typeName, id)
                match (instOpt) {
                    case Some(inst) =>
                        let ref = ConfigRef<Any>(inst)
                        for (l in lstArr) {
                            l.onLoaded(ref)
                        }
                    case None => ()
                }
            case None => ()
        }
    }

    public func dispatchChanged(typeName: String, id: String, field: String, oldValue: ?DynamicValue, newValue: ?DynamicValue): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                for (l in lstArr) {
                    l.onChanged(field, oldValue, newValue)
                }
            case None => ()
        }
    }

    public func dispatchReloaded(typeName: String, id: String): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                for (l in lstArr) {
                    l.onReloaded()
                }
            case None => ()
        }
    }

    public func dispatchSaved(typeName: String, id: String): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                for (l in lstArr) {
                    l.onSaved()
                }
            case None => ()
        }
    }

    public func dispatchValidationError(typeName: String, id: String, field: String, message: String): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                for (l in lstArr) {
                    l.onValidationError(field, message)
                }
            case None => ()
        }
    }

    public func dispatchError(typeName: String, id: String, error: ConfigException): Unit {
        let key = "${typeName}:${id}"
        let lst = synchronized(lock) {
            listeners.get(key)
        }
        match (lst) {
            case Some(lstArr) =>
                for (l in lstArr) {
                    l.onError(error)
                }
            case None => ()
        }
    }

    public func getListenerCount(typeName: String, id: String): Int64 {
        let key = "${typeName}:${id}"
        synchronized(lock) {
            match (listeners.get(key)) {
                case Some(lst) => lst.size
                case None => 0
            }
        }
    }
}
