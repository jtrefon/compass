Your previous response contained tool-call markup that could not be parsed — the tool call was NOT executed and your work stalled.

Attempt: {{attempt}}/{{max_attempts}}
Error: {{retry_reason}}

Re-issue your intent as ONE properly formatted tool call:
- Emit exactly one structured tool call in the documented format for this model.
- The call must be COMPLETE: every required argument present, strings properly
  delimited, and the call fully closed (no truncation).
- Do NOT describe the call in prose. Do NOT include the markup inside a code
  block or wrapped in extra tags. Do NOT repeat the malformed text.
- If you were waiting on the result of a previous tool, note that briefly, then
  issue the call.
