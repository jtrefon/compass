Your previous tool call was TRUNCATED — the model hit its output limit before the call was closed, so it was NOT executed and your work stalled.

Attempt: {{attempt}}/{{max_attempts}}
Error: {{retry_reason}}

Re-issue the SAME intent as a SHORT, complete tool call:

- The output limit is tight (~1000 tokens). A call that copies large content
  (entire files, huge blocks) CANNOT fit — it will be cut off again.
- For file edits: use a SMALL `old_string` anchor — at most a few lines that
  uniquely identify the change site (do NOT paste the whole file), or use
  `start_line`/`end_line` + `new_content` for line-range edits. If you need
  exact line numbers, `read` the file first (a read call is cheap and short).
- For writes: write the file in small pieces or via `bash` if the content is
  large.
- The call MUST be fully closed (all tags closed, all braces balanced) — a
  truncated call is rejected.
- Do NOT describe the call in prose. Do NOT repeat the truncated text.