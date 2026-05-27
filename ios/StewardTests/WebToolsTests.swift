//
//  WebToolsTests.swift
//  StewardTests
//
//  Covers WebSearchTool (Wikipedia OpenSearch) + WebFetchTool. Uses a
//  URLProtocol stub so tests are hermetic — no real network, fully
//  deterministic.
//

import XCTest
@testable import Steward

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    /// Maps from absolute-URL substring → canned response. The longest
    /// matching key wins, so tests can stub specific endpoints alongside
    /// catch-all fallbacks.
    nonisolated(unsafe) static var stubs: [(matches: (URL) -> Bool, response: (data: Data, statusCode: Int, headers: [String: String]))] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let match = Self.stubs.first(where: { $0.matches(url) })
        guard let (data, statusCode, headers) = match?.response else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: [:])!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let resp = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        stubs = []
    }
}

// MARK: - WebSearchTool tests

final class WebSearchToolTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_webSearch_parsesOpenSearchTuple() async throws {
        // Wikipedia OpenSearch: [query, titles[], descriptions[], urls[]]
        let body = #"["xerus",["Xerus","Xerus (genus)"],["Genus of squirrels","African ground squirrel genus"],["https://en.wikipedia.org/wiki/Xerus","https://en.wikipedia.org/wiki/Xerus_(genus)"]]"#
        let data = Data(body.utf8)
        StubURLProtocol.stubs = [(
            matches: { $0.host == "en.wikipedia.org" },
            response: (data, 200, ["Content-Type": "application/json"])
        )]
        let tool = WebSearchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebSearchArgs(query: "xerus", limit: nil))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebSearchResult.self, from: resultJSON)
        XCTAssertEqual(result.query, "xerus")
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.hits[0].title, "Xerus")
        XCTAssertEqual(result.hits[0].url, "https://en.wikipedia.org/wiki/Xerus")
        XCTAssertEqual(result.hits[1].summary, "African ground squirrel genus")
    }

    func test_webSearch_emptyHits_whenWikipediaReturnsEmptyArrays() async throws {
        let body = #"["nothingmatches",[],[],[]]"#
        let data = Data(body.utf8)
        StubURLProtocol.stubs = [(
            matches: { $0.host == "en.wikipedia.org" },
            response: (data, 200, ["Content-Type": "application/json"])
        )]
        let tool = WebSearchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebSearchArgs(query: "nothingmatches", limit: nil))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebSearchResult.self, from: resultJSON)
        XCTAssertEqual(result.hits.count, 0)
    }

    func test_webSearch_throws_onMalformedResponse() async throws {
        let data = Data("{\"oops\":\"not an array\"}".utf8)
        StubURLProtocol.stubs = [(
            matches: { $0.host == "en.wikipedia.org" },
            response: (data, 200, ["Content-Type": "application/json"])
        )]
        let tool = WebSearchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebSearchArgs(query: "x", limit: nil))
        do {
            _ = try await tool.invoke(argsJSON: argsJSON)
            XCTFail("expected decode failure")
        } catch let toolError as LLMToolError {
            XCTAssertEqual(toolError.code, "decode_failed")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_webSearch_throws_onHTTPError() async throws {
        StubURLProtocol.stubs = [(
            matches: { $0.host == "en.wikipedia.org" },
            response: (Data("Service Unavailable".utf8), 503, ["Content-Type": "text/plain"])
        )]
        let tool = WebSearchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebSearchArgs(query: "x", limit: nil))
        do {
            _ = try await tool.invoke(argsJSON: argsJSON)
            XCTFail("expected HTTP error")
        } catch let toolError as LLMToolError {
            XCTAssertEqual(toolError.code, "network_failed")
            XCTAssertTrue(toolError.message.contains("503"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}

// MARK: - WebFetchTool tests

final class WebFetchToolTests: XCTestCase {

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func test_webFetch_returnsBodyText_forTextHTMLWithTagStripping() async throws {
        let html = """
        <html>
        <head><title>T</title><style>.x{color:red}</style></head>
        <body>
          <script>alert('xss')</script>
          <h1>Hello</h1>
          <p>This is a <a href="x">link</a>.</p>
        </body>
        </html>
        """
        StubURLProtocol.stubs = [(
            matches: { $0.host == "example.com" },
            response: (Data(html.utf8), 200, ["Content-Type": "text/html; charset=utf-8"])
        )]
        let tool = WebFetchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebFetchArgs(url: "https://example.com/"))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebFetchResult.self, from: resultJSON)
        XCTAssertEqual(result.status, 200)
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.bodyText.contains("<"), "tags should be stripped: \(result.bodyText)")
        XCTAssertFalse(result.bodyText.contains("alert("), "script content should be dropped")
        XCTAssertTrue(result.bodyText.contains("Hello"))
        XCTAssertTrue(result.bodyText.contains("link"))
    }

    func test_webFetch_passesThroughPlainText() async throws {
        let body = "Just some plain text\nwith two lines."
        StubURLProtocol.stubs = [(
            matches: { $0.host == "example.com" },
            response: (Data(body.utf8), 200, ["Content-Type": "text/plain"])
        )]
        let tool = WebFetchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebFetchArgs(url: "https://example.com/x.txt"))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebFetchResult.self, from: resultJSON)
        XCTAssertEqual(result.bodyText, body)
    }

    func test_webFetch_truncates_aboveCapAndFlagsIt() async throws {
        // 80KB of 'a' → above the 64KB cap
        let big = String(repeating: "a", count: 80 * 1024)
        StubURLProtocol.stubs = [(
            matches: { $0.host == "example.com" },
            response: (Data(big.utf8), 200, ["Content-Type": "text/plain"])
        )]
        let tool = WebFetchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebFetchArgs(url: "https://example.com/big.txt"))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebFetchResult.self, from: resultJSON)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.bodyText.utf8.count, WebFetchTool.maxBodyBytes)
    }

    func test_webFetch_rejectsNonHTTPS() async throws {
        let tool = WebFetchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebFetchArgs(url: "http://example.com/"))
        do {
            _ = try await tool.invoke(argsJSON: argsJSON)
            XCTFail("expected scheme rejection")
        } catch let toolError as LLMToolError {
            XCTAssertEqual(toolError.code, "arguments_invalid")
            XCTAssertTrue(toolError.message.contains("https"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func test_webFetch_returnsStatusEvenOnHTTPError() async throws {
        StubURLProtocol.stubs = [(
            matches: { $0.host == "example.com" },
            response: (Data("not found".utf8), 404, ["Content-Type": "text/plain"])
        )]
        let tool = WebFetchTool(urlSession: StubURLProtocol.stubbedSession())
        let argsJSON = try ToolJSON.encode(WebFetchArgs(url: "https://example.com/missing"))
        let resultJSON = try await tool.invoke(argsJSON: argsJSON)
        let result = try ToolJSON.decode(WebFetchResult.self, from: resultJSON)
        XCTAssertEqual(result.status, 404)
        XCTAssertTrue(result.bodyText.contains("not found"))
    }

    func test_renderBody_dropsBinaryContent() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x02])
        let (text, truncated) = WebFetchTool.renderBody(data: bytes, contentType: "image/png")
        XCTAssertEqual(text, "")
        XCTAssertFalse(truncated)
    }
}
