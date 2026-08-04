import Foundation

/// Manages a single shared WKWebView session dedicated to web searches.
/// Reuses the same browser instance across calls for performance and
/// to maintain a natural browsing profile (cookies, history) that helps
/// avoid captcha challenges.
@MainActor
final class GoogleWebSearchEngine {
    static let shared = GoogleWebSearchEngine()

    private var session: WebKitSession?
    private var lastUsed: Date = .distantPast

    /// Serializes navigations against the single shared `WebKitSession`.
    /// Concurrent `web_search` calls would otherwise overwrite the session's
    /// `pendingResult` and re-issue `webView.load`, causing WKWebView to cancel
    /// the in-flight navigation (NSURLErrorCancelled / -999) across all of them.
    private var navigationChain: Task<String, Error>?

    private init() {}

    func search(query: String, maxResults: Int = 10) async throws -> String {
        // Chain onto any in-flight search so only one navigation runs at a time.
        let previous = navigationChain
        let task = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            return try await self.performSearch(query: query, maxResults: maxResults)
        }
        navigationChain = task
        return try await task.value
    }

    private func performSearch(query: String, maxResults: Int = 10) async throws -> String {
        let searchStart = ContinuousClock.now

        let engine = try await getSession()

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = "https://www.google.com/search?q=\(encoded)&hl=en&num=\(maxResults)"
        guard let url = URL(string: searchURL) else {
            throw AppError.networkError("Failed to build search URL for: \(query)")
        }

        // Navigate — returns the page's body text after JS rendering completes.
        // Retry once on cancellation: a stale/corrupted session navigation can
        // surface as NSURLErrorCancelled (-999); a fresh session recovers it.
        let pageText: String
        do {
            pageText = try await engine.navigate(to: url, timeout: 25)
        } catch {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                reset()
                let fresh = try await getSession()
                pageText = try await fresh.navigate(to: url, timeout: 25)
            } else {
                throw error
            }
        }

        if await engine.isGoogleCAPTCHA() {
            return """
            BLOCKED: Google presented a CAPTCHA challenge. This can happen due to:
            - Frequent searches from the same browser profile
            - Unusual request patterns
            Try again in a moment with a different query, or use web_browse to visit a URL directly.
            """
        }

        // Primary: parse from page text (most reliable — navigate already waited for full render)
        var results = parseTextSearchResults(pageText, max: maxResults)

        // Supplement: try JS extraction for richer results (gracefully ignored if it fails)
        if results.isEmpty {
            results = parseJSONLines(try await tryAwaitingSearchExtraction(engine, maxResults), max: maxResults)
        }

        if results.isEmpty {
            let totalMs = Int(searchStart.duration(to: ContinuousClock.now).components.seconds * 1000)
            return """
            No search results found for: "\(query)"
            Google returned unexpected page structure. Try a different query or use web_browse to visit a URL directly.
            """
        }

        lastUsed = Date()
        let totalMs = Int(searchStart.duration(to: ContinuousClock.now).components.seconds * 1000)
        return formatSearchResults(results, query: query)
    }

    func reset() {
        session?.close()
        session = nil
        lastUsed = .distantPast
    }

     private func getSession() async throws -> WebKitSession {
        if let existing = session, lastUsed.timeIntervalSinceNow > -3600 {
            return existing
        }
        session = WebKitSession(persistentData: true)
        lastUsed = Date()
        return session!
    }

    // MARK: - Safe JS extraction

    /// Wraps extractSearchResults in a try-catch so JS exceptions don't crash the tool.
    /// Returns empty string on any error — the text-based parser serves as the fallback.
    private func tryAwaitingSearchExtraction(_ engine: WebKitSession, _ max: Int) async -> String {
        do {
            return try await Task {
                return try await engine.extractSearchResults(max: max)
            }.value
        } catch {
            return ""
        }
    }

    // MARK: - JSON line parsing

    private func parseJSONLines(_ jsonLines: String, max: Int) -> [(title: String, url: String, snippet: String)] {
        var results: [(title: String, url: String, snippet: String)] = []
        for line in jsonLines.components(separatedBy: "\n").prefix(max) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let title = json["title"], !title.isEmpty else { continue }
            results.append((
                title: title,
                url: json["url"] ?? "",
                snippet: String((json["snippet"] ?? "").prefix(200))
            ))
        }
        return results
    }

    // MARK: - Text-based fallback parser

    /// Parse search results from raw page text (may be single-line or multi-line).
    /// Finds all external URLs and extracts surrounding text as title + snippet.
    private func parseTextSearchResults(_ text: String, max: Int) -> [(title: String, url: String, snippet: String)] {
        var results: [(title: String, url: String, snippet: String)] = []

        // Find all URLs in the text
        let urlPattern = "https?://[^\\s<>\"']+"
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: []) else { return [] }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))

        for match in matches {
            guard results.count < max else { break }

            let fullURL = nsText.substring(with: match.range)
            // Skip Google internal URLs
            guard isExternalURL(fullURL) else { continue }

            // Normalize: strip path after › for display URL
            var cleanURL = fullURL
            let fullURLNS = fullURL as NSString
            let sepRange = fullURLNS.range(of: " › ")
            if sepRange.location != NSNotFound {
                cleanURL = fullURLNS.substring(to: sepRange.location).trimmingCharacters(in: .whitespaces)
            }

            // Extract title: text before the URL (up to 120 chars)
            var title = ""
            if match.range.location > 0 {
                let beforeStart = match.range.location > 150 ? match.range.location - 150 : 0
                let beforeLength = match.range.location - beforeStart
                let beforeURL = nsText.substring(with: NSRange(location: beforeStart, length: beforeLength))
                let titleLines = beforeURL.components(separatedBy: CharacterSet.newlines).filter { !$0.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty }
                title = titleLines.last?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
                if title.count > 120 { title = String(title.prefix(120)) }
            }

            // Extract snippet: text after the URL (up to 200 chars)
            let afterStart = match.range.location + match.range.length
            let afterEnd = afterStart + 300 < text.utf16.count ? afterStart + 300 : text.utf16.count
            guard afterStart < text.utf16.count else { continue }
            var snippet = nsText.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart))
            // Clean up snippet
            if let dashRange = snippet.range(of: "—") {
                snippet = String(snippet[dashRange.upperBound...])
            }
            snippet = snippet.trimmingCharacters(in: .whitespaces)
            if snippet.count > 200 { snippet = String(snippet.prefix(200)) }

            // Validate title is meaningful
            guard title.count > 5 && !isGoogleNoise(title) else { continue }

            results.append((title: title, url: cleanURL, snippet: snippet))
        }

        return results
    }

    private func isURL(_ line: String) -> Bool {
        line.hasPrefix("http://") || line.hasPrefix("https://") ||
        line.hasPrefix("www.") ||
        (line.contains("://") && line.count < 200 && !line.contains(" "))
    }

    private func isExternalURL(_ line: String) -> Bool {
        isURL(line) && !isGoogleInternal(line)
    }

    private func isGoogleInternal(_ line: String) -> Bool {
        line.contains("google") || line.contains("gstatic") ||
        line.contains("youtube") || line.contains("webcache") ||
        line.contains("scholar") || line.contains("maps.google")
    }

    private func isGoogleNoise(_ line: String) -> Bool {
        line.contains("Google") || line.contains("Search") ||
        line.contains("Settings") || line.contains("Help") ||
        line.contains("Privacy") || line.contains("Terms") ||
        line.contains("Advertising") || line.contains("Business") ||
        line.count < 10
    }

    // MARK: - Formatting

    private func formatSearchResults(_ results: [(title: String, url: String, snippet: String)], query: String) -> String {
        var lines: [String] = ["Search results for: \"\(query)\" (\(results.count) results)"]
        lines.append("")

        for (i, r) in results.enumerated() {
            lines.append("[\(i + 1)] \(r.title)")
            if !r.url.isEmpty {
                lines.append("    URL: \(r.url)")
            }
            if !r.snippet.isEmpty {
                lines.append("    \(r.snippet)")
            }
            lines.append("")
        }

        lines.append("Use web_browse with action=open and a url from above to read a specific page.")
        return lines.joined(separator: "\n")
    }
}
