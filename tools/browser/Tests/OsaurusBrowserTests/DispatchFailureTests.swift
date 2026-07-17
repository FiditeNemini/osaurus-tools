import XCTest

@testable import OsaurusBrowser

/// Failure-normalization coverage at the `invoke` dispatch boundary for all
/// 21 tools. Every FAILURE result crossing the C ABI must be a canonical
/// envelope — either the normalized `{"ok":false,"kind",...}` shape or the
/// standard `{"ok":false,"error":{...}}` envelope the newer tools emit.
///
/// Split in two layers:
///  1. Live `invoke` calls through the C ABI for tools whose invalid-args
///     failure paths do not touch WebKit (safe under `swift test`).
///  2. Fixture-based checks of `normalizeBrowserResult` against the exact raw
///     failure shapes each remaining tool emits (their live failure paths
///     require a WKWebView, which the env-gated E2E suite covers).
final class DispatchFailureTests: XCTestCase {

    // MARK: - C ABI plumbing

    private typealias InitFn = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias FreeStringFn = @convention(c) (UnsafePointer<CChar>?) -> Void
    private typealias InvokeFn =
        @convention(c) (
            UnsafeMutableRawPointer?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?,
            UnsafePointer<CChar>?
        ) -> UnsafePointer<CChar>?

    private var ctx: UnsafeMutableRawPointer?
    private var invokeFn: InvokeFn!
    private var freeFn: FreeStringFn!
    private var destroyFn: DestroyFn!

    override func setUp() {
        super.setUp()
        guard let entry = osaurus_plugin_entry() else {
            XCTFail("osaurus_plugin_entry returned nil")
            return
        }
        // api struct layout: free_string, init, destroy, get_manifest, invoke, ...
        let base = entry.assumingMemoryBound(to: Optional<UnsafeRawPointer>.self)
        guard let freeRaw = base.advanced(by: 0).pointee,
            let initRaw = base.advanced(by: 1).pointee,
            let destroyRaw = base.advanced(by: 2).pointee,
            let invokeRaw = base.advanced(by: 4).pointee
        else {
            XCTFail("plugin api function pointers missing")
            return
        }
        freeFn = unsafeBitCast(freeRaw, to: FreeStringFn.self)
        destroyFn = unsafeBitCast(destroyRaw, to: DestroyFn.self)
        invokeFn = unsafeBitCast(invokeRaw, to: InvokeFn.self)
        ctx = unsafeBitCast(initRaw, to: InitFn.self)()
    }

    override func tearDown() {
        if let ctx = ctx { destroyFn(ctx) }
        ctx = nil
        super.tearDown()
    }

    private func invoke(_ toolId: String, _ payload: String, type: String = "tool") -> String {
        guard let ctx = ctx else { return "" }
        var result = ""
        toolId.withCString { idPtr in
            type.withCString { typePtr in
                payload.withCString { payloadPtr in
                    guard let out = invokeFn(ctx, typePtr, idPtr, payloadPtr) else { return }
                    result = String(cString: out)
                    freeFn(out)
                }
            }
        }
        return result
    }

    private func parse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A failure result is canonical iff it parses as JSON with `ok == false`,
    /// and — when it uses the normalized `kind` shape — deterministic kinds
    /// are not flagged retryable.
    private func assertCanonicalFailure(
        _ raw: String, tool: String, file: StaticString = #file, line: UInt = #line
    ) {
        guard let dict = parse(raw) else {
            XCTFail("\(tool): failure result is not JSON: \(raw)", file: file, line: line)
            return
        }
        XCTAssertEqual(dict["ok"] as? Bool, false, "\(tool): expected ok:false, got \(raw)", file: file, line: line)
        if let kind = dict["kind"] as? String {
            XCTAssertNotNil(dict["message"], "\(tool): normalized envelope missing message", file: file, line: line)
            if kind == "invalid_args" || kind == "not_found" {
                XCTAssertEqual(
                    dict["retryable"] as? Bool, false,
                    "\(tool): \(kind) must not be retryable", file: file, line: line)
            }
        } else {
            XCTAssertNotNil(dict["error"], "\(tool): ok:false envelope missing error", file: file, line: line)
        }
    }

    // MARK: - Live invoke: invalid-args failures that never touch WebKit

    func test_invoke_legacyToolsInvalidArgsAreNormalizedFailures() {
        // Payloads chosen so JSON decoding of required args fails before any
        // browser access, keeping `swift test` WebKit-free.
        let cases: [(tool: String, payload: String)] = [
            ("browser_navigate", "{}"),  // missing url
            ("browser_click", "not json"),
            ("browser_type", "{}"),  // missing text
            ("browser_select", "{}"),  // missing values
            ("browser_hover", "not json"),
            ("browser_scroll", "not json"),
            ("browser_press_key", "{}"),  // missing key
            ("browser_wait_for", "not json"),
            ("browser_execute_script", "{}"),  // missing script
            ("browser_do", "{}"),  // missing actions
        ]
        for c in cases {
            let out = invoke(c.tool, c.payload)
            assertCanonicalFailure(out, tool: c.tool)
            let dict = parse(out)
            XCTAssertEqual(
                dict?["kind"] as? String, "invalid_args",
                "\(c.tool): expected invalid_args, got \(out)")
        }
    }

    func test_invoke_newToolsInvalidArgsAreCanonicalFailures() {
        let cases: [(tool: String, payload: String)] = [
            ("browser_set_viewport", "{}"),  // missing width/height
            ("browser_handle_dialog", "{\"action\": \"explode\"}"),
            ("browser_cookies", "{\"action\": \"munch\"}"),
            ("browser_cookies", "{\"action\": \"set\"}"),  // set without cookie
        ]
        for c in cases {
            let out = invoke(c.tool, c.payload)
            assertCanonicalFailure(out, tool: c.tool)
        }
    }

    func test_invoke_unknownToolIsNonRetryableNotFound() throws {
        let out = invoke("browser_frobnicate", "{}")
        let dict = try XCTUnwrap(parse(out))
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "not_found")
        XCTAssertEqual(dict["retryable"] as? Bool, false)
    }

    func test_invoke_unknownCapabilityTypeIsFailure() throws {
        let out = invoke("browser_navigate", "{}", type: "route")
        let dict = try XCTUnwrap(parse(out))
        XCTAssertEqual(dict["ok"] as? Bool, false)
    }

    // MARK: - Fixture shapes: failure outputs that require a live browser

    func test_browserDependentFailureShapesNormalize() {
        // Exact raw strings the remaining tools emit on failure. Their live
        // paths need a WKWebView, so we assert the dispatch boundary
        // (normalizeBrowserResult) converts each shape to a canonical failure.
        let shapes: [(tool: String, raw: String)] = [
            ("browser_snapshot", "Error: No page loaded. Call browser_navigate first to load a page."),
            ("browser_snapshot", "Error: Failed to parse snapshot"),
            ("browser_navigate", "{\"error\": \"Navigation timed out after 30.0 seconds\"}"),
            ("browser_click", "{\"error\": \"No element matches ref E5\"}"),
            (
                "browser_screenshot",
                "{\"error\": \"Failed to capture screenshot. Make sure a page is loaded with browser_navigate first.\"}"
            ),
            (
                "browser_execute_script",
                "{\"error\": \"JavaScript execution failed: boom. Make sure a page is loaded with browser_navigate first.\"}"
            ),
            ("browser_execute_script", "{\"error\": \"Script error: ReferenceError\"}"),
            (
                "browser_do",
                "Error: Action 1 (click) failed: No element matches ref E9\n\n- page: X | url: https://x\n(no interactive elements found)"
            ),
        ]
        for shape in shapes {
            let out = normalizeBrowserResult(shape.raw)
            assertCanonicalFailure(out, tool: shape.tool)
        }
    }

    func test_canonicalEnvelopeFailuresPassThroughUnchanged() {
        // Tools already emitting the standard envelope (open_login,
        // reset_session, lock, viewport, dialog, cookies, console/network
        // inspection) must not be rewritten by the boundary.
        let envelopes = [
            "{\"error\":{\"code\":\"LOGIN_TIMEOUT\",\"message\":\"Login window did not close within the timeout.\"},\"ok\":false}",
            "{\"error\":{\"code\":\"RESET_FAILED\",\"message\":\"Failed to remove the active agent's session data store.\"},\"ok\":false}",
            "{\"error\":{\"code\":\"LOCK_HELD\",\"message\":\"Browser is already locked by 'a'.\"},\"ok\":false}",
            "{\"error\":{\"code\":\"LOGIN_REQUIRED\",\"domain\":\"x.com\",\"message\":\"Navigation landed on a login page (x.com)\"},\"ok\":false}",
        ]
        for envelope in envelopes {
            XCTAssertEqual(normalizeBrowserResult(envelope), envelope)
            assertCanonicalFailure(envelope, tool: "envelope-passthrough")
        }
    }

    // MARK: - Success outputs stay untouched

    func test_successShapesAreNotRewritten() {
        let successes = [
            "Action: navigate to https://example.com succeeded\n- page: Example | url: https://example.com",
            "{\"success\": true}",
            "{\"data\":{\"count\":0,\"messages\":[]},\"ok\":true}",
        ]
        for s in successes {
            XCTAssertEqual(normalizeBrowserResult(s), s)
        }
    }
}
