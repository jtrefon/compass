## web_fetch — Fetch a URL and extract its readable content

**When to use:** Reading full articles, documentation pages, or API references after discovering them with web_search.

**Parameters:**
- action (optional, string): `open` (navigate to a URL — default), `read` (re-read current page), `click` (click an element by CSS selector), `links` (list links on the page), `go_back`, `go_forward`, `reload`, `close` (end the session).
- url (string): The full URL to fetch. Required for `action=open`.
- session_id (string): The browser session to act on. Omit for `action=open` to create a new session (the response returns the new session id); required for all other actions.
- selector (string): CSS selector for `action=click` (e.g. `a.nav-link`, `#submit-btn`).
- max_chars (optional, integer): Truncation limit for the extracted text (default 10000, max 50000).

**Expected output:** Page title and main body text.
status: success | error
content.text: page title and readable content

**Common situations & recovery:**
- URL unreachable: Check the URL or try web_search to find an alternative source.
- First call to a page: `web_fetch` with `action=open` and `url` (omit `session_id`). Follow-up actions on the same page: pass the returned `session_id` with `action=read`/`links`/`click`.
