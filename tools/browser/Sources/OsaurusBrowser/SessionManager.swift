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
            let uuid = UUID(uuidString: stored)
        {
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

    /// Tears down the active agent's session: removes the pooled browser,
    /// wipes every cookie / localStorage / IndexedDB / cache entry under its
    /// `WKWebsiteDataStore`, and clears the persisted `profile_id` so the next
    /// `driver()` call mints a brand-new UUID and a fresh isolated store.
    ///
    /// We deliberately do *not* call `WKWebsiteDataStore.remove(forIdentifier:)`.
    /// That API races with the WebKit Networking / Storage XPC processes that
    /// still hold the per-identifier store open even after the last
    /// `WKWebView` is released; the internal completion lambda inside
    /// `WebsiteDataStore::removeDataStoreWithIdentifierImpl` then dispatches to
    /// a NULL `RunLoop` and segfaults the host process inside
    /// `com.apple.WebKit.WebsiteDataStoreIO`. Wiping the store in place via
    /// `removeData(ofTypes:modifiedSince:)` and orphaning the on-disk directory
    /// under a freshly minted identifier is observably equivalent (next session
    /// is logged out and isolated) without the crash.
    func resetActiveSession(completion: @escaping (Bool, String?) -> Void) {
        let profileId = currentProfileId()
        let removed: HeadlessBrowser? = lock.withLock {
            pool.removeValue(forKey: profileId)
        }
        DispatchQueue.main.async {
            // Grab the live data store *before* tearing down the webview so a
            // strong reference outlives the wipe.
            let store =
                removed?.websiteDataStore
                ?? WKWebsiteDataStore(forIdentifier: profileId)
            removed?.tearDown()

            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                HostBridge.shared.configDelete("profile_id")
                completion(true, nil)
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
