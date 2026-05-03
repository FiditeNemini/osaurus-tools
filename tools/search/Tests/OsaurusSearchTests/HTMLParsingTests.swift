import XCTest

@testable import OsaurusSearch

final class HTMLParsingTests: XCTestCase {

    // MARK: parseDDGHTML

    func test_parseDDGHTML_unwrapsUDDGRedirects() {
        let html = """
            <div class="result"><a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Example A</a>
              <a class="result__snippet">Snippet text</a></div>
            <div class="result"><a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fb">Example B</a>
              <a class="result__snippet">Other snippet</a></div>
            """
        let hits = parseDDGHTML(html, max: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].url, "https://example.com/a")
        XCTAssertEqual(hits[0].title, "Example A")
        XCTAssertEqual(hits[0].snippet, "Snippet text")
        XCTAssertEqual(hits[1].url, "https://example.com/b")
        XCTAssertEqual(hits[1].engine, "ddg")
    }

    func test_parseDDGHTML_returnsEmptyOnUnknownMarkup() {
        let hits = parseDDGHTML("<html><body><p>nothing here</p></body></html>", max: 5)
        XCTAssertEqual(hits.count, 0)
    }

    func test_parseDDGHTML_respectsMax() {
        var html = ""
        for i in 0..<10 {
            html += """
                <div class="result"><a class="result__a" href="https://example.com/\(i)">Title \(i)</a></div>
                """
        }
        let hits = parseDDGHTML(html, max: 3)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: parseBingHTML

    func test_parseBingHTML_extractsTitleAndSnippet() {
        let html = """
            <li class="b_algo"><h2><a href="https://example.com/x">Headline</a></h2>
              <p>This is the snippet.</p></li>
            """
        let hits = parseBingHTML(html, max: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].title, "Headline")
        XCTAssertEqual(hits[0].url, "https://example.com/x")
        XCTAssertEqual(hits[0].snippet, "This is the snippet.")
        XCTAssertEqual(hits[0].engine, "bing_html")
    }

    // MARK: parseBraveHTML — modern markup

    func test_parseBraveHTML_extractsModernSnippet() {
        // Brave's 2026 markup: per-result wrapper has class "snippet", title is an
        // <a class="title ..."> and description sits in <div class="description ...">.
        // The legacy regex (looking for class="...title..." on a <div> tag) couldn't
        // match this because the title is on an <a>, and there is no `snippet-title`
        // class — just `title`.
        let html = """
            <html><body>
              <div class="snippet svelte-1ajsqxo">
                <a href="https://example.com/a" class="title desktop-default-regular line-clamp-1 svelte-1ajsqxo" target="_self">Example A</a>
                <div class="description desktop-default-regular t-secondary line-clamp-2 svelte-1ajsqxo">Snippet for A.</div>
              </div>
              <div class="snippet svelte-jmfu5f" data-pos="1" data-type="web">
                <div class="result-wrapper">
                  <a href="https://example.com/b" target="_self" class="svelte-14r20fy l1">site name + favicon</a>
                  <a href="https://example.com/b" class="title search-snippet-title line-clamp-1 svelte-14r20fy" target="_self">Example B</a>
                  <div class="description desktop-default-regular t-secondary line-clamp-2">Snippet for B.</div>
                </div>
              </div>
            </body></html>
            """
        let hits = parseBraveHTML(html, max: 5)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].title, "Example A")
        XCTAssertEqual(hits[0].url, "https://example.com/a")
        XCTAssertEqual(hits[0].snippet, "Snippet for A.")
        XCTAssertEqual(hits[0].engine, "brave_html")
        XCTAssertEqual(hits[1].title, "Example B")
        XCTAssertEqual(hits[1].url, "https://example.com/b")
    }

    func test_parseBraveHTML_skipsAds() {
        // Sponsored results come through the same `.snippet` wrapper but with
        // data-type="ad" and a `/a/redirect?click_url=...` href. These must not appear
        // in organic results.
        let html = """
            <div class="snippet svelte-jmfu5f" data-type="ad">
              <a href="/a/redirect?click_url=https%3A%2F%2Fads.example.com" class="svelte-14r20fy l1">ad-headline</a>
              <a href="/a/redirect?click_url=https%3A%2F%2Fads.example.com" class="title">Sponsored Thing</a>
              <div class="description">paid placement</div>
            </div>
            <div class="snippet svelte-1ajsqxo">
              <a href="https://example.com/keep" class="title">Keep</a>
              <div class="description">organic</div>
            </div>
            """
        let hits = parseBraveHTML(html, max: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].url, "https://example.com/keep")
    }

    func test_parseBraveHTML_emptyOnUnknownMarkup() {
        XCTAssertEqual(parseBraveHTML("<html><body><p>nothing</p></body></html>", max: 5).count, 0)
    }

    func test_isLikelyChallengePage_detectsCaptcha() {
        XCTAssertTrue(isLikelyChallengePage("<html>tiny</html>"))
        let big = String(repeating: "x", count: 5000)
        XCTAssertFalse(isLikelyChallengePage("<html><body>\(big)</body></html>"))
        XCTAssertTrue(
            isLikelyChallengePage("<html><body>\(big)<p>captcha required</p></body></html>")
        )
    }
}
