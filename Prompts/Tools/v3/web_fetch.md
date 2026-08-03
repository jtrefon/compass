## web_fetch — Fetch a URL and extract its readable content

**When to use:** Reading full articles, documentation pages, or API references after discovering them with web_search.

**Parameters:**
- url (required, string): The full URL to fetch.

**Expected output:** Page title and main body text.
status: success | error
content.text: page title and readable content

**Common situations & recovery:**
- URL unreachable: Check the URL or try web_search to find an alternative source.
