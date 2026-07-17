import XCTest

@testable import OsaurusTime

/// Edge cases around malformed payloads and invalid timezone identifiers.
final class EdgeCaseTests: XCTestCase {

    private func assertInvalidArgs(
        _ block: @autoclosure () throws -> [String: Any],
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try block(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? ToolError)?.code, "INVALID_ARGS",
                "expected INVALID_ARGS, got \(error)", file: file, line: line)
        }
    }

    // MARK: malformed payload JSON → INVALID_ARGS (not silent defaults)

    func test_currentTime_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try CurrentTimeTool().run(args: "{not json"))
    }

    func test_currentTime_emptyPayloadStillUsesDefaults() throws {
        let data = try CurrentTimeTool().run(args: "")
        XCTAssertEqual(data["timezone"] as? String, TimeZone.current.identifier)
    }

    func test_listTimezones_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try ListTimezonesTool().run(args: "]["))
    }

    func test_listTimezones_emptyPayloadReturnsAll() throws {
        let data = try ListTimezonesTool().run(args: "")
        XCTAssertGreaterThan(data["count"] as? Int ?? 0, 100)
    }

    func test_formatDate_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try FormatDateTool().run(args: "{\"timestamp\": }"))
    }

    func test_parseDate_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try ParseDateTool().run(args: "not json at all"))
    }

    func test_convertTimezone_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try ConvertTimezoneTool().run(args: "{\"to\":"))
    }

    func test_addDuration_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try AddDurationTool().run(args: "{{"))
    }

    func test_diffDates_malformedJSONIsInvalidArgs() {
        assertInvalidArgs(try DiffDatesTool().run(args: "{\"from\": \"2025-01-01\""))
    }

    // MARK: invalid timezone identifiers → INVALID_ARGS

    func test_parseDate_unknownTimezoneIsInvalidArgs() {
        assertInvalidArgs(
            try ParseDateTool().run(args: #"{"date": "2025-04-21", "timezone": "Mars/Olympus_Mons"}"#))
    }

    func test_convertTimezone_unknownTargetIsInvalidArgs() {
        assertInvalidArgs(
            try ConvertTimezoneTool().run(args: #"{"timestamp": 0, "to": "Not/AZone"}"#))
    }

    func test_addDuration_unknownTimezoneIsInvalidArgs() {
        assertInvalidArgs(
            try AddDurationTool().run(args: #"{"timestamp": 0, "seconds": 1, "timezone": "Nowhere/Land"}"#))
    }

    func test_listTimezones_unmatchedPrefixReturnsEmptyNotError() throws {
        let data = try ListTimezonesTool().run(args: #"{"prefix": "zzz/nothing"}"#)
        XCTAssertEqual(data["count"] as? Int, 0)
        XCTAssertEqual((data["identifiers"] as? [String])?.isEmpty, true)
    }

    // MARK: timezone id whitespace / case sensitivity

    func test_resolveTimezone_emptyStringFallsBackToSystem() throws {
        XCTAssertEqual(try resolveTimezone("").identifier, TimeZone.current.identifier)
    }

    func test_resolveTimezone_isCaseSensitivePerIANA() {
        // Foundation treats IANA identifiers case-sensitively; a miscased id
        // must surface as INVALID_ARGS (with the list_timezones hint) rather
        // than silently resolving to the system zone.
        XCTAssertThrowsError(try resolveTimezone("america/new_york")) { error in
            XCTAssertEqual((error as? ToolError)?.code, "INVALID_ARGS")
        }
    }
}
