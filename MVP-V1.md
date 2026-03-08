# MVP-V1.md — OpenClaw Agent Swarm Delegation Protocol

## Objective

Build a single orchestrator workflow where:

1. Tasks run in background (parallel)
2. Native memory is used before delegating
3. Human is notified only on escalation/review-ready moments

## Default Protocol (for explicit delegation requests)

Trigger phrases include (examples):

- “delegate this task”
- “do this in background”
- “run this in parallel”

### 1) Task Intake

Capture:

- objective
- scope
- constraints
- expected output
- acceptance criteria

### 2) Native Memory First

- Query native memory for relevant prior decisions/context
- Synthesize only the most relevant context
- Produce compact memory-informed task brief

### 3) Spawn Background Worker

Launch sub-agent session(s) with:

- objective
- acceptance criteria
- constraints
- memory-informed context
- expected deliverable format

### 4) Monitor + Deterministic Retry

- Worker runs asynchronously in background
- If blocked/failing, retry with refined instructions
- Retries are bounded and explicit

### 5) Escalate Only When Needed

Escalate only for actionable events:

- READY_FOR_REVIEW
- BLOCKED_DECISION
- RETRY_EXHAUSTED

No routine progress spam.

---

## Status Lifecycle

Each delegated task must be tracked with one of:

- `running`
- `blocked_decision`
- `retrying`
- `retry_exhausted`
- `ready_for_review`
- `done`

## Parallelism

- Multiple delegated tasks can run concurrently
- Each task must have a label/id for traceability
- MVP expectation: >=3 active concurrent tasks supported

## Acceptance Criteria

1. **Memory-before-delegation**
   - Every delegated task includes a memory-informed context brief
2. **Background execution**
   - Delegated tasks run asynchronously without blocking chat
3. **Parallel support**
   - At least 3 concurrent delegated tasks can be active
4. **Escalation-only notifications**
   - Notifications limited to:
     - READY_FOR_REVIEW
     - BLOCKED_DECISION
     - RETRY_EXHAUSTED
5. **Deterministic retries**
   - Retry behavior bounded and status-explicit
6. **Clear handoff output**
   - Completion includes:
     - what changed
     - test/check status
     - next action

## MVP Test Plan

1. **Single-task happy path**
   - Delegate one task → completes → one review-ready/done summary
2. **Memory relevance check**
   - Delegate task tied to prior context → brief reflects constraints/preferences
3. **Parallel run**
   - Delegate 3 tasks quickly → all enter `running` independently
4. **Blocked path**
   - Induce ambiguity → exactly one BLOCKED_DECISION with crisp question
5. **Retry exhaustion**
   - Force repeated failure → RETRY_EXHAUSTED once with top reason + options

## Out of Scope (v2+)

- Multi-model router heuristics (Codex/Claude/Gemini)
- Git worktree/tmux orchestration scripts
- Full CI/PR auto-review pipeline
- Screenshot enforcement and advanced quality gates
