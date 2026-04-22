import Foundation

// MARK: - Host API (v2 ABI mirror)

/// C function-pointer types matching the Osaurus v2 host API.
/// These are the host-provided callbacks the plugin receives at init time.
/// We only mirror the fields we actually use (config + log); the trailing
/// fields are kept in the layout to match the host's struct shape.
typealias osr_config_get_t = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_t = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_t = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_t = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

/// Layout-compatible mirror of `osr_host_api`. Only the prefix fields are
/// strongly typed; later fields use opaque pointers since this plugin doesn't
/// use them. The struct must keep the same field ordering as the C header so
/// pointer arithmetic from the host lines up correctly.
struct osr_host_api {
    var version: UInt32

    var config_get: osr_config_get_t?
    var config_set: osr_config_set_t?
    var config_delete: osr_config_delete_t?
    var db_exec: osr_db_exec_t?
    var db_query: osr_db_query_t?
    var log: osr_log_t?

    var dispatch: UnsafeRawPointer?
    var task_status: UnsafeRawPointer?
    var dispatch_cancel: UnsafeRawPointer?
    var dispatch_clarify: UnsafeRawPointer?

    var complete: UnsafeRawPointer?
    var complete_stream: UnsafeRawPointer?
    var embed: UnsafeRawPointer?
    var list_models: UnsafeRawPointer?

    var http_request: UnsafeRawPointer?

    var file_read: UnsafeRawPointer?

    var list_active_tasks: UnsafeRawPointer?
    var send_draft: UnsafeRawPointer?
    var dispatch_interrupt: UnsafeRawPointer?
    var dispatch_add_issue: UnsafeRawPointer?
}

// MARK: - Host bridge

/// Swift-friendly wrapper around the host callbacks. Calls are no-ops when
/// the host isn't available (e.g. unit tests run the plugin without v2 init),
/// so callers can use the bridge unconditionally.
final class HostBridge: @unchecked Sendable {
    /// Singleton — populated by `osaurus_plugin_entry_v2(host)`. Reads/writes
    /// are protected by `lock`.
    static let shared = HostBridge()

    private let lock = NSLock()
    private var api: osr_host_api?

    private init() {}

    /// Called from the v2 entry point. Copies the host API struct into the
    /// process so the plugin can call back into Osaurus for config + log.
    func install(api: osr_host_api) {
        lock.withLock { self.api = api }
    }

    /// True when a v2 host has installed callbacks. Tests and v1-only hosts
    /// will see `false`, in which case callers should fall back to safe
    /// in-process state instead of expecting per-agent persistence.
    var isInstalled: Bool {
        return lock.withLock { api?.config_get != nil }
    }

    /// Returns the value for `key`, scoped to the currently active agent
    /// (Osaurus sets the agent context before calling our `invoke`). Empty
    /// strings are coerced to `nil` to match the keychain behavior of
    /// missing keys.
    func configGet(_ key: String) -> String? {
        let captured: osr_config_get_t? = lock.withLock { api?.config_get }
        guard let getFn = captured else { return nil }
        return key.withCString { keyPtr in
            guard let cstr = getFn(keyPtr) else { return nil }
            let s = String(cString: cstr)
            return s.isEmpty ? nil : s
        }
    }

    /// Stores `value` under `key`, scoped to the currently active agent.
    /// Silently no-ops when the host isn't installed.
    func configSet(_ key: String, _ value: String) {
        let captured: osr_config_set_t? = lock.withLock { api?.config_set }
        guard let setFn = captured else { return }
        key.withCString { keyPtr in
            value.withCString { valPtr in
                setFn(keyPtr, valPtr)
            }
        }
    }

    /// Removes `key` for the active agent. No-op when absent.
    func configDelete(_ key: String) {
        let captured: osr_config_delete_t? = lock.withLock { api?.config_delete }
        guard let delFn = captured else { return }
        key.withCString { keyPtr in
            delFn(keyPtr)
        }
    }

    /// Structured log to the Osaurus Insights tab. Levels: 0=debug, 1=info,
    /// 2=warning, 3=error. No-op when host isn't installed.
    func log(_ level: Int32, _ message: String) {
        let captured: osr_log_t? = lock.withLock { api?.log }
        guard let logFn = captured else { return }
        message.withCString { msgPtr in
            logFn(level, msgPtr)
        }
    }
}
