import XCTest

@testable import OsaurusSearch

final class RedactionTests: XCTestCase {

    // MARK: redactSecrets

    func test_redactSecrets_removesConfiguredSecretValues() {
        let secrets = ["GOOGLE_CSE_API_KEY": "AIzaSyFAKEKEY123", "GOOGLE_CSE_CX": "cx-abc"]
        let text = "Google CSE: Invalid URL: https://www.googleapis.com/customsearch/v1?key=AIzaSyFAKEKEY123&cx=cx-abc&q=hi"
        let out = redactSecrets(text, secrets: secrets)
        XCTAssertFalse(out.contains("AIzaSyFAKEKEY123"), "key leaked: \(out)")
        XCTAssertFalse(out.contains("cx-abc"), "cx leaked: \(out)")
        XCTAssertTrue(out.contains("[REDACTED]"))
        XCTAssertTrue(out.contains("Google CSE"), "non-secret context should survive: \(out)")
    }

    func test_redactSecrets_removesPercentEncodedSecretValues() {
        let secrets = ["TAVILY_API_KEY": "tvly:abc/def"]
        let encoded = "tvly:abc/def".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let out = redactSecrets("request to https://api.tavily.com/?k=\(encoded) failed", secrets: secrets)
        XCTAssertFalse(out.contains("abc/def"))
        XCTAssertFalse(out.contains(encoded))
    }

    func test_redactSecrets_scrubsKeyQueryParamsEvenWithoutConfiguredSecret() {
        let out = redactSecrets(
            "GET https://www.googleapis.com/customsearch/v1?key=SOMEKEY&cx=SOMECX&q=hello returned 403",
            secrets: [:]
        )
        XCTAssertFalse(out.contains("SOMEKEY"), "key leaked: \(out)")
        XCTAssertFalse(out.contains("SOMECX"), "cx leaked: \(out)")
        XCTAssertTrue(out.contains("q=hello"), "non-secret params should survive: \(out)")
    }

    func test_redactSecrets_leavesCleanTextAlone() {
        let text = "Tavily returned status 500"
        XCTAssertEqual(redactSecrets(text, secrets: ["TAVILY_API_KEY": "k123"]), text)
    }

    // MARK: failureAttempt

    func test_failureAttempt_redactsErrorText() {
        let attempt = failureAttempt(
            provider: "google_cse",
            message: "Invalid URL: https://www.googleapis.com/customsearch/v1?key=SECRET123&cx=CX9",
            secrets: ["GOOGLE_CSE_API_KEY": "SECRET123"]
        )
        XCTAssertEqual(attempt["provider"] as? String, "google_cse")
        XCTAssertEqual(attempt["ok"] as? Bool, false)
        let error = attempt["error"] as? String ?? ""
        XCTAssertFalse(error.contains("SECRET123"))
        XCTAssertFalse(error.contains("CX9"))
    }

    // MARK: all-backends-failed envelope

    func test_runWebOrNews_allBackendsFailedCarriesRedactedAttempts() {
        // Pinning google_cse with only one of the two required secrets fails
        // synchronously (no network). The NO_RESULTS envelope must carry an
        // ok:false attempt for it and no secret material anywhere in the payload.
        let params = SearchParams(
            query: "anything",
            max_results: 5,
            offset: 0,
            site: nil, filetype: nil, time_range: nil, region: nil,
            provider: "google_cse",
            secrets: ["GOOGLE_CSE_API_KEY": "SECRETVALUE42"],
            vertical: .web
        )
        XCTAssertThrowsError(try runWebOrNews(params)) { err in
            guard let toolErr = err as? ToolError else {
                XCTFail("Expected ToolError, got \(err)")
                return
            }
            XCTAssertEqual(toolErr.code, "NO_RESULTS")
            let attempts = toolErr.data?["attempts"] as? [[String: Any]] ?? []
            XCTAssertEqual(attempts.count, 1)
            XCTAssertEqual(attempts[0]["provider"] as? String, "google_cse")
            XCTAssertEqual(attempts[0]["ok"] as? Bool, false)
            let serialized = String(describing: toolErr.data) + toolErr.message + (toolErr.hint ?? "")
            XCTAssertFalse(serialized.contains("SECRETVALUE42"), "secret leaked in envelope: \(serialized)")
        }
    }
}
