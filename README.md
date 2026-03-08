# OpenClaw Agent Swarm

Reusable baseline for running a **replicable, delegation-first OpenClaw setup** across multiple instances.

## What this gives you

- A practical folder/file baseline for continuity (`AGENTS.md`, `SOUL.md`, `USER.md`, `TOOLS.md`, memory files)
- A delegation protocol tuned for background-parallel execution with escalation-only notifications
- A concrete operating spec in `MVP-V1.md`
- Heartbeat + cron guidance so each instance can run proactive checks without noise
- A quick-start setup flow for new machines

## Quick Start

1. Clone this repo on the target machine.
2. Run deterministic apply:
   - `./scripts/apply-mvp-v1.sh /path/to/.openclaw/workspace`
3. Run verification:
   - `./scripts/verify-mvp-v1.sh /path/to/.openclaw/workspace`
4. Update only local identity/env fields (`USER.md`, `TOOLS.md`).
5. Run a smoke test:
   - delegation request
   - one background execution
   - one escalation-only completion message

See `REPLICATE.md` for full replication instructions.

## Required Files

- `AGENTS.md` – Operating model and behavioral rules
- `SOUL.md` – Tone/persona and communication style
- `USER.md` – Human profile and preferences
- `TOOLS.md` – Local environment notes
- `MEMORY.md` – Long-term curated memory (main session only)
- `HEARTBEAT.md` – Optional heartbeat checklist
- `MVP-V1.md` – Delegation operating spec and acceptance criteria
- `memory/YYYY-MM-DD.md` – Daily raw memory logs
- `.mvp-v1-manifest.json` – applied-template/version record

## Replication Checklist

- [ ] OpenClaw installed and running
- [ ] GitHub CLI (`gh`) authenticated (if using GitHub automation)
- [ ] Baseline files copied
- [ ] `USER.md` and `TOOLS.md` customized
- [ ] `memory/` created
- [ ] Heartbeat policy verified
- [ ] Delegation protocol tested end-to-end

## Suggested Test Scenario

Use one real project task (not toy file creation):

1. Human asks for a concrete outcome (e.g., triage CI failures).
2. Main agent gathers constraints + acceptance criteria.
3. Main agent spawns background worker(s).
4. Worker returns result with artifacts.
5. Main agent only escalates if review/decision is needed.

## License

MIT
