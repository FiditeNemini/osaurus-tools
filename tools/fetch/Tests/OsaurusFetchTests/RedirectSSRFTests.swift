import XCTest

@testable import OsaurusFetch

/// Minimal in-process HTTP server bound to 127.0.0.1 used to exercise the
/// redirect path without touching the network. Routes map a request path to
/// a raw HTTP response.
final class LoopbackHTTPServer {
    private let socketFD: Int32
    let port: UInt16
    private let routes: [String: (status: String, headers: [String: String], body: String)]
    private var acceptThread: Thread?
    private var running = true

    init?(routes: [String: (status: String, headers: [String: String], body: String)]) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &len)
            }
        }

        self.routes = routes
        self.socketFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while running {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else { break }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buffer, buffer.count)
            var path = "/"
            if n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8) {
                let firstLine = request.split(separator: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2 { path = String(parts[1]) }
            }
            let response: String
            if let route = routes[path] {
                var headerLines = route.headers.map { "\($0.key): \($0.value)" }
                headerLines.append("Content-Length: \(route.body.utf8.count)")
                headerLines.append("Connection: close")
                response =
                    "HTTP/1.1 \(route.status)\r\n"
                    + headerLines.joined(separator: "\r\n")
                    + "\r\n\r\n" + route.body
            } else {
                response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            }
            _ = response.withCString { write(client, $0, strlen($0)) }
            close(client)
        }
    }

    func stop() {
        running = false
        close(socketFD)
    }

    deinit { stop() }
}

final class RedirectSSRFTests: XCTestCase {

    private func makeServer(
        _ routes: [String: (status: String, headers: [String: String], body: String)]
    ) throws -> LoopbackHTTPServer {
        return try XCTUnwrap(LoopbackHTTPServer(routes: routes), "failed to start loopback server")
    }

    private func runRequest(
        _ url: String,
        allowPrivate: Bool,
        followRedirects: Bool = true
    ) throws -> HTTPResult {
        return try executeRequest(
            url: URL(string: url)!,
            method: "GET",
            headers: [:],
            body: .none,
            timeout: 10,
            maxBytes: 1024 * 1024,
            followRedirects: followRedirects,
            allowPrivate: allowPrivate
        )
    }

    private func assertSSRFBlocked(
        redirectTarget: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let server = try makeServer([
            "/go": (
                status: "302 Found",
                headers: ["Location": redirectTarget],
                body: ""
            )
        ])
        defer { server.stop() }
        do {
            _ = try runRequest("http://127.0.0.1:\(server.port)/go", allowPrivate: false)
            XCTFail("expected SSRF_BLOCKED for redirect to \(redirectTarget)", file: file, line: line)
        } catch let err as ToolError {
            XCTAssertEqual(err.code, "SSRF_BLOCKED", "got \(err.code): \(err.message)", file: file, line: line)
            XCTAssertTrue(
                err.message.contains("Redirect"),
                "expected redirect-specific message, got: \(err.message)", file: file, line: line)
        }
    }

    func test_redirectToLoopbackIsBlocked() throws {
        try assertSSRFBlocked(redirectTarget: "http://127.0.0.1:1234/secret")
    }

    func test_redirectToCloudMetadataIsBlocked() throws {
        try assertSSRFBlocked(redirectTarget: "http://169.254.169.254/latest/meta-data/")
    }

    func test_redirectToPrivateRangeIsBlocked() throws {
        try assertSSRFBlocked(redirectTarget: "http://10.0.0.5/admin")
        try assertSSRFBlocked(redirectTarget: "http://192.168.1.1/router")
    }

    func test_redirectToBlockedHostnameIsBlocked() throws {
        try assertSSRFBlocked(redirectTarget: "http://localhost:8080/")
        try assertSSRFBlocked(redirectTarget: "http://metadata.google.internal/")
    }

    func test_allowPrivateFollowsRedirectToLoopback() throws {
        var routes: [String: (status: String, headers: [String: String], body: String)] = [:]
        let server = try XCTUnwrap(
            LoopbackHTTPServer(routes: [
                "/final": (status: "200 OK", headers: ["Content-Type": "text/plain"], body: "landed")
            ]))
        defer { server.stop() }
        routes["/go"] = (
            status: "302 Found",
            headers: ["Location": "http://127.0.0.1:\(server.port)/final"],
            body: ""
        )
        let redirector = try makeServer(routes)
        defer { redirector.stop() }

        let result = try runRequest("http://127.0.0.1:\(redirector.port)/go", allowPrivate: true)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(String(data: result.body, encoding: .utf8), "landed")
        XCTAssertEqual(result.redirectChain.count, 1)
    }

    func test_redirectLoopStopsWithTooManyRedirects() throws {
        // Self-redirect: /loop → /loop forever. allowPrivate bypasses the SSRF
        // guard so only the redirect bound can stop it.
        let server = try makeServer([
            "/loop": (
                status: "302 Found",
                headers: ["Location": "/loop"],
                body: ""
            )
        ])
        defer { server.stop() }
        do {
            _ = try runRequest("http://127.0.0.1:\(server.port)/loop", allowPrivate: true)
            XCTFail("expected TOO_MANY_REDIRECTS")
        } catch let err as ToolError {
            XCTAssertEqual(err.code, "TOO_MANY_REDIRECTS")
        }
    }

    func test_followRedirectsFalseReturnsThe3xxWithoutError() throws {
        let server = try makeServer([
            "/go": (
                status: "302 Found",
                headers: ["Location": "http://10.0.0.5/admin"],
                body: ""
            )
        ])
        defer { server.stop() }
        let result = try runRequest(
            "http://127.0.0.1:\(server.port)/go",
            allowPrivate: true,
            followRedirects: false
        )
        XCTAssertEqual(result.status, 302)
    }

    // MARK: Delegate-level unit tests (no sockets)

    func test_delegateBlocksPrivateRedirectTarget() {
        let delegate = FetchDelegate(maxBytes: 1024, followRedirects: true, allowPrivate: false)
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/")!,
            statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        var forwarded: URLRequest? = URLRequest(url: URL(string: "https://example.com/")!)
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "http://169.254.169.254/latest/meta-data/")!)
        ) { forwarded = $0 }
        XCTAssertNil(forwarded, "redirect to metadata IP must not be followed")
        XCTAssertEqual(delegate.redirectBlockError?.code, "SSRF_BLOCKED")
    }

    func test_delegateAllowsPublicRedirectTarget() {
        let delegate = FetchDelegate(maxBytes: 1024, followRedirects: true, allowPrivate: false)
        let task = URLSession.shared.dataTask(with: URL(string: "https://example.com/")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/")!,
            statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil)!
        var forwarded: URLRequest?
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.org/next")!)
        ) { forwarded = $0 }
        XCTAssertEqual(forwarded?.url?.absoluteString, "https://example.org/next")
        XCTAssertNil(delegate.redirectBlockError)
    }
}
