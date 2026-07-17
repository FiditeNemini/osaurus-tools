import OsaurusPluginABI
import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import OsaurusSearch

/// SDK-backed conformance checks: manifest shape, ABI entry-point contract
/// (v1 and v2 exports), and the canonical failure envelope.
final class SDKConformanceTests: XCTestCase {

    private func manifestJSON() throws -> String {
        let entry = try XCTUnwrap(osaurus_plugin_entry_v2(nil))
        let api = entry.assumingMemoryBound(to: OsrPluginAPI.self).pointee
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
        let entry = try XCTUnwrap(osaurus_plugin_entry_v2(nil))
        let api = entry.assumingMemoryBound(to: OsrPluginAPI.self).pointee
        XCTAssertEqual(api.version, OsrABIVersion.v2)
    }

    func test_canonicalFailureEnvelopeShape() throws {
        // This plugin's own wire failures keep the legacy {ok, error} shape;
        // the canonical envelope is what the SDK renders for new failure
        // paths — pin its shape here.
        try assertCanonicalFailure(
            Envelope.failure(.invalidArgs, "query must be a non-empty string"),
            kind: .invalidArgs)
    }
}
