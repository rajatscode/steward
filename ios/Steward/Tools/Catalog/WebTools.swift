//
//  WebTools.swift
//  Steward
//
//  Two tools that give the agent a window onto the public web without
//  any API key or paid service:
//
//   - web.search → Wikipedia OpenSearch API. Free, unkeyed, stable wire
//     format documented at
//     https://www.mediawiki.org/wiki/API:Opensearch — returns
//     [query, titles[], descriptions[], urls[]]. Sufficient for factual
//     lookups; not a general-web crawler. If the user wants Google-grade
//     search later, swap the backend behind this tool — the LLMTool
//     surface stays the same.
//
//   - web.fetch → URLSession GET against an absolute URL. Capped at 64KB
//     of decoded text so a runaway page doesn't blow up the context
//     window. HTTPS only. Strips HTML to a best-effort plain-text rendering.
//
//  Both tools are injection-friendly: the `URLSession` is constructor-
//  injected so tests can supply a `URLProtocol`-stubbed session.
//

import Foundation

// MARK: - web.search (Wikipedia OpenSearch)

struct WebSearchArgs: Codable, Equatable, Sendable {
    let query: String
    let limit: Int?
}

struct WebSearchHit: Codable, Equatable, Sendable {
    let title: String
    let summary: String
    let url: String
}

struct WebSearchResult: Codable, Equatable, Sendable {
    let query: String
    let hits: [WebSearchHit]
}

struct WebSearchTool: LLMTool {
    let id: String = ToolID.webSearch.rawValue
    let description: String = """
    Search Wikipedia for a topic. Returns a small list of {title, summary, url} hits. \
    Use for factual questions (people, places, concepts, events) where a Wikipedia \
    article is likely to exist. Not a general-web search engine — for arbitrary URLs \
    use web.fetch instead.
    """
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["query"],
      "properties": {
        "query": {"type": "string", "description": "The topic to search for."},
        "limit": {"type": ["integer", "null"], "description": "Max hits (1-10, default 5)."}
      }
    }
    """

    let urlSession: URLSession
    let endpoint: URL

    init(
        urlSession: URLSession = .shared,
        endpoint: URL = URL(string: "https://en.wikipedia.org/w/api.php")!
    ) {
        self.urlSession = urlSession
        self.endpoint = endpoint
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(WebSearchArgs.self, from: argsJSON)
        let limit = max(1, min(args.limit ?? 5, 10))

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "opensearch"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "search", value: args.query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else {
            throw LLMToolError(code: "arguments_invalid", message: "could not build search URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Outkeep/0.1 (iOS personal app; +https://rajatscode.local)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMToolError(
                code: "network_failed",
                message: "web.search transport error: \(error.localizedDescription)"
            )
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMToolError(
                code: "network_failed",
                message: "web.search HTTP \(http.statusCode)"
            )
        }

        // OpenSearch returns a 4-tuple JSON array:
        // [query: String, titles: [String], descriptions: [String], urls: [String]]
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any],
              parsed.count == 4,
              let titles = parsed[1] as? [String],
              let descriptions = parsed[2] as? [String],
              let urls = parsed[3] as? [String] else {
            throw LLMToolError(
                code: "decode_failed",
                message: "web.search: unexpected OpenSearch response shape"
            )
        }
        let count = min(titles.count, descriptions.count, urls.count)
        let hits: [WebSearchHit] = (0..<count).map { i in
            WebSearchHit(
                title: titles[i],
                summary: descriptions[i],
                url: urls[i]
            )
        }
        return try ToolJSON.encode(WebSearchResult(query: args.query, hits: hits))
    }
}

// MARK: - web.fetch (URLSession GET, truncated)

struct WebFetchArgs: Codable, Equatable, Sendable {
    let url: String
}

struct WebFetchResult: Codable, Equatable, Sendable {
    let url: String
    let status: Int
    let contentType: String?
    /// Best-effort plain-text rendering of the response body. HTML is
    /// stripped to text; non-text content returns an empty body.
    let bodyText: String
    /// True if `bodyText` was truncated to fit the 64KB cap.
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case url, status
        case contentType = "content_type"
        case bodyText    = "body_text"
        case truncated
    }
}

struct WebFetchTool: LLMTool {
    static let maxBodyBytes = 64 * 1024  // 64KB after decode

    let id: String = ToolID.webFetch.rawValue
    let description: String = """
    Fetch the contents of a URL via HTTPS GET and return a best-effort \
    plain-text rendering of the body (HTML is stripped). Body is truncated \
    at \(WebFetchTool.maxBodyBytes / 1024)KB. Only HTTPS URLs are accepted.
    """
    let jsonSchemaForArgs: String = """
    {
      "type": "object",
      "required": ["url"],
      "properties": {
        "url": {"type": "string", "description": "Absolute HTTPS URL."}
      }
    }
    """

    let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func invoke(argsJSON: String) async throws -> String {
        let args = try ToolJSON.decode(WebFetchArgs.self, from: argsJSON)
        guard let url = URL(string: args.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" else {
            throw LLMToolError(
                code: "arguments_invalid",
                message: "web.fetch: only absolute https:// URLs are allowed"
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Outkeep/0.1 (iOS personal app)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LLMToolError(
                code: "network_failed",
                message: "web.fetch transport error: \(error.localizedDescription)"
            )
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")

        let (text, truncated) = Self.renderBody(data: data, contentType: contentType)
        return try ToolJSON.encode(WebFetchResult(
            url: args.url,
            status: status,
            contentType: contentType,
            bodyText: text,
            truncated: truncated
        ))
    }

    /// Best-effort body → text. HTML gets a naive tag-strip, JSON / plain text
    /// pass through, binary content returns an empty string. Truncates to
    /// `maxBodyBytes` of UTF-8.
    static func renderBody(data: Data, contentType: String?) -> (text: String, truncated: Bool) {
        let lowered = contentType?.lowercased() ?? ""
        let isText = lowered.contains("text/")
            || lowered.contains("json")
            || lowered.contains("xml")
            || lowered.contains("javascript")
            // Many endpoints serve UTF-8 text without an explicit content-type.
            || lowered.isEmpty
        guard isText, let raw = String(data: data, encoding: .utf8) else {
            return ("", false)
        }
        let stripped: String
        if lowered.contains("html") || raw.contains("<html") || raw.contains("<HTML") {
            stripped = stripHTML(raw)
        } else {
            stripped = raw
        }
        let collapsed = stripped
            .replacingOccurrences(of: "\r\n", with: "\n")
            // Collapse runs of whitespace > 2 newlines into 2 (keeps paragraph breaks).
            .components(separatedBy: "\n\n\n")
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if collapsed.utf8.count <= maxBodyBytes {
            return (collapsed, false)
        }
        // Truncate by utf8 byte budget. Drop incomplete trailing scalar.
        let bytes = Array(collapsed.utf8.prefix(maxBodyBytes))
        let truncated = String(decoding: bytes, as: UTF8.self)
        return (truncated, true)
    }

    /// Naive HTML → text. Drops `<script>` / `<style>` blocks, strips
    /// remaining tags, decodes the most common entities. Good enough for
    /// the agent to read article-style content; not a real DOM renderer.
    static func stripHTML(_ html: String) -> String {
        var s = html
        // Drop script + style blocks entirely.
        for pattern in [#"<script[\s\S]*?</script>"#, #"<style[\s\S]*?</style>"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
        }
        // Strip all remaining tags.
        if let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#, options: []) {
            let range = NSRange(s.startIndex..., in: s)
            s = tagRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        // Decode the most common entities.
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse repeated whitespace.
        if let wsRegex = try? NSRegularExpression(pattern: #"[ \t]+"#, options: []) {
            let range = NSRange(s.startIndex..., in: s)
            s = wsRegex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
