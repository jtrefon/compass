## plan — Structured multi-step task planning

**When to use:** Any multi-file task where you need to track progress across multiple turns. **Without a plan, you risk forgetting steps when context is trimmed or tool results accumulate.** A plan is your checklist — it survives context compression and keeps you focused until every step is delivered.

**Actions:**
- "init": Start planning. Enter research phase — use all tools to explore.
- "finishTask": End current phase. Provide task breakdown (research) or mark current task done and advance (execution).
- "raiseQuestion": Pause and ask the user for clarification.
- "breakOutCantContinue": Abort the plan with a reason.

**Expected output:** Plan progress confirmation.
status: success | error
message: "Plan updated"
