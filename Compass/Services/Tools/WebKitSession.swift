import AppKit
import Foundation
import WebKit

/// Shared WKWebView engine for navigation, content extraction, and SPA-aware detection.
///
/// Design: This class is NOT @MainActor. All WKWebView interactions are marshaled
/// to the main thread via DispatchQueue.main.sync. Navigation waits happen on a
/// background thread via NSCondition, avoiding any MainActor blocking that would
/// prevent delegate callbacks from firing (which was the original deadlock).
final class WebKitSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let window: NSWindow
    private let webView: WKWebView
    private var currentURL: URL?
    private var contentWatcherInjected = false

    /// Navigation result signal — set up before navigation, resolved by delegate.
    private var pendingResult: NavigationResult?

    init(persistentData: Bool) {
        // Hidden 1x1 window — required for WKWebView to render JS on macOS.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.hasShadow = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.orderFront(nil)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = persistentData ? .default() : .nonPersistent()
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let userContent = WKUserContentController()
        config.userContentController = userContent

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)

        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        userContent.add(self, name: "contentReady")
    }

    deinit {
        DispatchQueue.main.sync {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "contentReady")
        }
    }

    private func onMain(_ fn: @escaping () -> Void) {
        if Thread.isMainThread {
            fn()
        } else {
            DispatchQueue.main.sync(execute: fn)
        }
    }

    // MARK: - Public API

    func navigate(to url: URL, timeout: TimeInterval = 25) async throws -> String {
        currentURL = url
        contentWatcherInjected = false
        return try await boundedTimeout(seconds: timeout) {
            try await self.navigateInternal(to: url)
        }
    }

    func reload() async throws -> String {
        contentWatcherInjected = false
        guard let url = currentURL else {
            throw AppError.networkError("No current URL to reload.")
        }
        return try await navigate(to: url)
    }

    func goBack() async throws -> String {
        contentWatcherInjected = false
        return try await boundedTimeout(seconds: 25) {
            try await self.goBackInternal()
        }
    }

    func goForward() async throws -> String {
        contentWatcherInjected = false
        return try await boundedTimeout(seconds: 25) {
            try await self.goForwardInternal()
        }
    }

    func getText() async throws -> String {
        try await evaluateJS("(document.body?.textContent) || ''")
    }

    func getLinks() async throws -> String {
        let js = """
        (function() {
            var links = Array.from(document.querySelectorAll('a[href]'));
            var out = [];
            for (var i = 0; i < links.length && i < 200; i++) {
                var a = links[i];
                out.push(JSON.stringify({
                    text: (a.textContent || '').trim().substring(0, 80),
                    href: a.href || a.getAttribute('href')
                }));
            }
            return out.join('\\n');
        })();
        """
        let raw = try await evaluateJS(js)
        return raw.isEmpty ? "No links found." : raw
    }

    func click(selector: String, timeout: TimeInterval = 25) async throws -> String {
        let clickJS = """
        (function() {
            var el = document.querySelector('\(selector)');
            if (!el) return 'NO_ELEMENT';
            if (el.tagName === 'A') {
                var href = el.getAttribute('href');
                if (href) return 'NAVIGATE:' + href;
            }
            el.click();
            return 'CLICKED';
        })();
        """
        let result = try await evaluateJS(clickJS)
        if result.hasPrefix("NAVIGATE:"),
           let href = String(result.dropFirst(9)).removingPercentEncoding,
           let url = URL(string: href, relativeTo: currentURL) {
            return try await navigate(to: url, timeout: timeout)
        }
        contentWatcherInjected = false
        return try await boundedTimeout(seconds: timeout) {
            try await self.waitForContentAfterClick()
        }
    }

    func evaluateJS(_ js: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            onMain {
                self.webView.evaluateJavaScript(js) { result, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: (result as? String) ?? "")
                    }
                }
            }
        }
    }

    /// Universal search result extraction: finds all external links on the page
    /// and extracts title + URL + snippet regardless of the search engine's DOM.
    /// Works with Google, Bing, DuckDuckGo, and any other search engine.
    /// Uses textContent (not innerText) to avoid reflow-related exceptions.
    func extractSearchResults(max: Int) async throws -> String {
        let js = """
        (function() {
            try {
                var results = [];
                var seen = {};
                var allLinks = document.querySelectorAll('a[href]');

                // Google: find result containers by looking for <h3> elements
                var h3s = document.querySelectorAll('h3');
                for (var i = 0; i < h3s.length && results.length < 20; i++) {
                    var h3 = h3s[i];
                    var title = (h3.textContent || '').trim();
                    if (!title || title.length < 5) continue;

                    // Find the link inside the h3 or near it
                    var link = h3.querySelector('a');
                    if (!link) {
                        var parent = h3.parentElement;
                        if (parent) link = parent.querySelector('a[href]');
                    }
                    if (!link) continue;

                    var href = link.href || link.getAttribute('href') || '';
                    if (!href || href.indexOf('://') === -1) continue;

                    // Skip internal links
                    if (href.indexOf('google') !== -1 || href.indexOf('youtube') !== -1 ||
                        href.indexOf('maps') !== -1 || href.indexOf('scholar') !== -1 ||
                        href.indexOf('webcache') !== -1) continue;

                    // Deduplicate
                    var key = href.substring(0, 80);
                    if (seen[key]) continue;
                    seen[key] = true;

                    // Find snippet: text after the link in the same container
                    var snippet = '';
                    var container = h3.parentElement;
                    if (container) {
                        var snippetEl = container.querySelector('[data-snc], [data-attrid], [class*="snippet"], [class*="description"]');
                        if (snippetEl) snippet = (snippetEl.textContent || '').trim();
                        if (!snippet) {
                            var allText = (container.textContent || '').trim();
                            snippet = allText.substring(title.length).trim();
                            if (snippet.length > 300) snippet = snippet.substring(0, 250);
                        }
                    }

                    // Normalize URL
                    var url = href;
                    try { url = new URL(href).href; } catch(e) {}

                    results.push(JSON.stringify({title:title,url:url,snippet:(snippet||'').substring(0,200)}));
                }

                // Fallback: if h3-based extraction got nothing, scan all links
                if (results.length === 0) {
                    for (var j = 0; j < allLinks.length && results.length < max; j++) {
                        var a = allLinks[j];
                        var href2 = a.href || '';
                        if (!href2 || href2.indexOf('://') === -1) continue;
                        // Skip internal
                        if (href2.indexOf('google') !== -1 || href2.indexOf('javascript') !== -1) continue;

                        var key2 = href2.substring(0, 80);
                        if (seen[key2]) continue;
                        seen[key2] = true;

                        var title2 = (a.textContent || '').trim().substring(0, 100);
                        if (!title2) title2 = href2.substring(0, 80);
                        results.push(JSON.stringify({title:title2,url:href2,snippet:''}));
                    }
                }

                return results.join('\\n');
            } catch(e) {
                return '';
            }
        })();
        """
        return try await evaluateJS(js)
    }

    func isGoogleCAPTCHA() async -> Bool {
        let js = """
        (function() {
            var body = (document.body?.textContent) || '';
            return body.indexOf('recaptcha') !== -1 ||
                   body.indexOf('Please verify you are a human') !== -1 ||
                   body.indexOf('unusual traffic') !== -1 ||
                   body.indexOf('verify you are not a robot') !== -1;
        })();
        """
        return (try? await evaluateJS(js)) == "true"
    }

    func close() {
        onMain {
            self.pendingResult?.resolve(text: "(session closed)")
            self.pendingResult = nil
            self.webView.loadHTMLString("", baseURL: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            injectContentWatcher()
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            pendingResult?.resolve(error: error)
            pendingResult = nil
        }
    }

    nonisolated public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            pendingResult?.resolve(error: error)
            pendingResult = nil
        }
    }

    // MARK: - WKScriptMessageHandler

    nonisolated public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.name == "contentReady" else { return }
            let bodyValue = message.body as? String ?? ""
            pendingResult?.resolve(text: bodyValue.isEmpty ? "(empty page)" : bodyValue)
            pendingResult = nil
        }
    }

    // MARK: - Internal navigation

    private func navigateInternal(to url: URL) async throws -> String {
        try await waitForNavigation {
            self.onMain {
                self.webView.load(URLRequest(url: url, timeoutInterval: 25))
            }
        }
    }

    private func goBackInternal() async throws -> String {
        try await waitForNavigation {
            self.onMain {
                self.webView.goBack()
            }
        }
    }

    private func goForwardInternal() async throws -> String {
        try await waitForNavigation {
            self.onMain {
                self.webView.goForward()
            }
        }
    }

    private func waitForContentAfterClick() async throws -> String {
        try await waitForNavigation {
            self.injectContentWatcher()
        }
    }

    /// Set up navigation, then wait on a background thread for the delegate
    /// to resolve the result. The wait uses NSCondition (blocking) on a detached
    /// thread, so it never blocks the main thread or MainActor executor.
    private func waitForNavigation(_ setup: @escaping () -> Void) async throws -> String {
        let result = NavigationResult()

        onMain {
            self.pendingResult = result
            setup()
        }

        // Wait on a background thread — this blocks the detached thread, NOT main thread.
        // MainActor remains free to process WKWebView delegate callbacks.
        return try await Task.detached(priority: .userInitiated) {
            try result.wait()
        }.value
    }

    // MARK: - Content Watcher

    private func injectContentWatcher() {
        guard !contentWatcherInjected else { return }
        contentWatcherInjected = true

       let js = """
        (function() {
            if (window.__contentWatchInjected) return;
            window.__contentWatchInjected = true;

            function signal(text) {
                try { window.webkit.messageHandlers.contentReady.postMessage(text); }
                catch(e) {}
            }

            // Strip non-content elements from a node (mutates DOM)
            function stripNonContent(node) {
                ['script','style','nav','footer','header','aside','noscript','link','meta'].forEach(function(s) {
                    Array.from(node.querySelectorAll(s)).forEach(function(el) { el.remove(); });
                });
            }

            function getContent() {
                // Always strip style/script/etc first, then extract text
                stripNonContent(document);

                var article = document.querySelector('article');
                if (article && ((article.textContent||'').trim().length || 0) > 200) return (article.textContent||'').trim();
                var main = document.querySelector('main, [role="main"], #content, .content');
                if (main && ((main.textContent||'').trim().length || 0) > 200) return (main.textContent||'').trim();
                var body = document.body;
                if (!body) return null;
                var text = (body.textContent||'').trim();
                if (text.length > 300) return text;
                return null;
            }

            var content = getContent();
            if (content) { signal(content); return; }

            var obs = new MutationObserver(function() {
                content = getContent();
                if (content) { obs.disconnect(); signal(content); }
            });
            obs.observe(document.body || document.documentElement, {
                childList: true, subtree: true, attributes: false, characterData: true
            });

            setTimeout(function() {
                obs.disconnect();
                content = getContent();
                signal(content || '(empty page)');
            }, 18000);
        })();
        """
        onMain {
            self.webView.evaluateJavaScript(js) { _, _ in }
        }
    }

    // MARK: - Timeout

    private func boundedTimeout(seconds: TimeInterval, operation: @escaping () async throws -> String) async throws -> String {
        let opTask = Task {
            try await operation()
        }

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            opTask.cancel()
        }

        do {
            let result = try await opTask.value
            watchdog.cancel()
            return result
        } catch {
            watchdog.cancel()
            onMain {
                self.pendingResult?.resolve(text: "(timed out after \(Int(seconds))s)")
                self.pendingResult = nil
            }
            throw (error as? CancellationError) != nil
                ? AppError.networkError("Timed out after \(Int(seconds))s.")
                : error
        }
    }
}

// MARK: - Thread-safe signal object

/// Synchronous signal object that can be waited on from any thread.
/// Uses NSCondition for efficient blocking (no CPU spinning).
private final class NavigationResult {
    private let condition = NSCondition()
    private var resolvedText: String?
    private var resolvedError: Error?

    func resolve(text: String) {
        condition.lock()
        defer { condition.unlock() }
        resolvedText = text
        condition.signal()
    }

    func resolve(error: Error) {
        condition.lock()
        defer { condition.unlock() }
        resolvedError = error
        condition.signal()
    }

    func wait() throws -> String {
        condition.lock()
        defer { condition.unlock() }
        while resolvedText == nil && resolvedError == nil {
            condition.wait()
        }
        if let resolvedError {
            throw resolvedError
        }
        return resolvedText ?? "(no result)"
    }
}
