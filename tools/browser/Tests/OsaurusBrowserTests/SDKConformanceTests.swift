import OsaurusPluginABI
import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import OsaurusBrowser

/// SDK-backed conformance checks: manifest shape, ABI entry-point contract
/// (v1 and v2 exports), and the canonical failure envelope at the real
/// dispatch boundary.
final class SDKConformanceTests: XCTestCase {

    private func pluginAPI() throws -> OsrPluginAPI {
        let entry = try XCTUnwrap(osaurus_plugin_entry_v2(nil))
        return entry.assumingMemoryBound(to: OsrPluginAPI.self).pointee
    }

    private func manifestJSON() throws -> String {
        let api = try pluginAPI()
        let cString = try XCTUnwrap(api.get_manifest?(nil))
        defer { api.free_string?(cString) }
        return String(cString: cString)
    }

    func test_manifestIsConformant() throws {
        try ManifestConformance.assertConformant(manifestJSON())
    }

    func test_v2EntryConformsToABI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry_v2(nil), manifestJSON: manifestJSON())
    }

    func test_v1EntryConformsToABI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry(), manifestJSON: manifestJSON())
    }

    func test_v2EntryDeclaresABIVersion2() throws {
        let api = try pluginAPI()
        XCTAssertEqual(api.version, OsrABIVersion.v2)
    }

    func test_unknownToolInvokeIsCanonicalNotFoundFailure() throws {
        // Live invoke through the C ABI: the unknown-tool path never touches
        // WebKit and must cross the boundary as the SDK's canonical failure.
        let api = try pluginAPI()
        let ctx = try XCTUnwrap(api.`init`?())
        defer { api.destroy?(ctx) }

        var result = ""
        "tool".withCString { typePtr in
            "browser_frobnicate".withCString { idPtr in
                "{}".withCString { payloadPtr in
                    guard let out = api.invoke?(ctx, typePtr, idPtr, payloadPtr) else { return }
                    result = String(cString: out)
                    api.free_string?(out)
                }
            }
        }
        try assertCanonicalFailure(result, kind: .notFound)
    }
}
