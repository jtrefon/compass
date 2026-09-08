## note — Working Memory

### WHAT
Write a finding to your persistent working memory. Notes survive context resets; raw tool results do not.

### WHEN
- After EVERY `read` call — capture what you learned
- After `search` results that reveal structure — capture the key findings
- After `bash` output that reveals build/test status — capture the result
- Before a context reset — ensure all critical findings are noted
- NOT for code you're about to edit (use intent='edit_target' instead)

### HOW
- action: "add" (new note), "update" (revise section), "clear" (remove section)
- section: Use file names for file-specific findings, "architecture" for structure, "risks" for issues, "decisions" for choices
- content: 1-3 sentences. Include file:line references for later surgical re-reads. Note risks with (RISK) or (CRITICAL). Do NOT copy code — reference it by file:line.
- intent: "finding" (read to understand — raw read disposable after noting) or "edit_target" (read to edit — raw read preserved through context resets). Defaults to finding.

### OUTPUT
status: success | duplicate | error
message: confirmation with note count

### EXAMPLES

After reading PaymentService.php:
```
note(action="add", section="PaymentService", intent="finding",
     content="Stripe+PayPal. processPayment() L34. NO amount validation (RISK). Hardcoded key in constructor (CRITICAL).")
```

Before editing checkout.js:
```
note(action="add", section="checkout.js", intent="edit_target",
     content="Need to add amount validation at L23 before processPayment call.")
```

Updating a section with new findings:
```
note(action="update", section="PaymentService", intent="finding",
     content="Reviewed: hardcoded Stripe key (CRITICAL), no amount validation (RISK), no webhook signature verification (CRITICAL).")
```

### RULES
- 1-3 sentences per note. Not a paragraph.
- Include file:line references. Don't copy code.
- Note risks with (RISK), (CRITICAL), (GOOD) tags.
- If you get `status: duplicate`, use `action: "update"` instead of "add".
- Your notes ARE your memory. If you don't note it, you lose it on reset.
