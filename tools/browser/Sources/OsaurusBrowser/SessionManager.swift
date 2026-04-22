import AppKit
import Foundation
import WebKit

/// Per-agent browser session manager.
///
/// Osaurus injects per-agent context before each tool invocation, so any
/// `host.config_get("profile_id")` call returns a different value per agent
/// without the plugin needing to know the agent UUID. We use that to:
///
/// 1. Generate a stable per-agent `profile_id` UUID on first use and persist it
///    via `host.config_set`.
/// 2. Lazily spawn a `HeadlessBrowser` bound to a `WKWebsiteDataStore(forIdentifier:)`
///    keyed on that UUID. Cookies, localStorage, IndexedDB, etc. survive across
///    runs — and stay isolated between agents.
///
/// When the host isn't available (unit tests, v1 ABI host), we fall back to a
/// single shared in-memory profile so the plugin still works.
final class SessionManager: @unchecked Sendable {
    static let shared = SessionManager()

    private let lock = NSLock()
    private var pool: [UUID: HeadlessBrowser] = [:]

    /// Stable identifier used when the host isn't available (tests, v1 ABI).
    /// All callers share one ephemeral profile in that case.
    private let fallbackProfileId = UUID()

    private init() {}

    /// Resolves the active agent's profile UUID. If none is stored yet, mints
    /// a new one and persists it via `host.config_set`. Falls back to a
    /// process-wide UUID when the host bridge isn't installed.
    func currentProfileId() -> UUID {
        guard HostBridge.shared.isInstalled else {
            return fallbackProfileId
        }
        if let stored = HostBridge.shared.configGet("profile_id"),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let new = UUID()
        HostBridge.shared.configSet("profile_id", new.uuidString)
        return new
    }

    /// Returns the active agent's `HeadlessBrowser`, creating it on first call.
    /// Subsequent calls within the same agent context return the same instance.
    func driver() -> HeadlessBrowser {
        let profileId = currentProfileId()
        return lock.withLock {
            if let existing = pool[profileId] { return existing }
            let new = HeadlessBrowser(profileId: profileId)
            pool[profileId] = new
            return new
        }
    }

    /// Tears down the active agent's session: removes the pooled browser and
    /// deletes its on-disk `WKWebsiteDataStore`. Next `driver()` call respawns
    /// a fresh one. The default keychain entry (`profile_id`) is also cleared
    /// so the next session gets a brand-new UUID.
    func resetActiveSession(completion: @escaping (Bool, String?) -> Void) {
        let profileId = currentProfileId()
        let removed: HeadlessBrowser? = lock.withLock {
            return pool.removeValue(forKey: profileId)
        }
        // Tear down the existing webview on main thread before removing the
        // data store, otherwise WebKit may complain about an in-use store.
        DispatchQueue.main.async {
            removed?.tearDown()
            HostBridge.shared.configDelete("profile_id")
            if #available(macOS 14.0, *) {
                WKWebsiteDataStore.remove(forIdentifier: profileId) { error in
                    if let error = error {
                        completion(false, error.localizedDescription)
                    } else {
                        completion(true, nil)
                    }
                }
            } else {
                completion(false, "Per-agent sessions require macOS 14 or newer")
            }
        }
    }

    /// All known profile UUIDs. Used for cleanup on plugin destroy.
    func knownProfileIds() -> [UUID] {
        return lock.withLock { Array(pool.keys) }
    }

    /// Tears down every pooled browser. Called from the plugin destroy path.
    func shutdownAll() {
        let drivers: [HeadlessBrowser] = lock.withLock {
            let all = Array(pool.values)
            pool.removeAll()
            return all
        }
        DispatchQueue.main.async {
            for d in drivers { d.tearDown() }
        }
    }
}
