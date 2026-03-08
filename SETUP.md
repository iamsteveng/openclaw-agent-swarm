# Setup Steps for New OpenClaw Instances

## 1) Prerequisites

- OpenClaw installed
- Access to workspace directory
- Optional: `gh` CLI authenticated for repo workflows

## 2) Apply Deterministic MVP Template

From this repo directory:

```bash
chmod +x scripts/*.sh
./scripts/apply-mvp-v1.sh /path/to/.openclaw/workspace
```

This applies the exact MVP core files, creates missing memory files, and writes `.mvp-v1-manifest.json`.

Verify:

```bash
./scripts/verify-mvp-v1.sh /path/to/.openclaw/workspace
```

## 3) Customize Identity + Operator Profile

Edit:

- `USER.md`: name, timezone, communication preferences
- `TOOLS.md`: machine/local notes
- `SOUL.md`: adjust voice if needed

## 4) Validate Behavior

Run these checks:

- Main session reads context files at session start
- Heartbeat returns `HEARTBEAT_OK` when no action is needed
- Reminder/cron messages are concise and contextual
- Delegation runs in background with escalation-only updates

## 5) Optional Automation

- Add cron reminders for maintenance checks
- Add periodic heartbeat checklist tasks in `HEARTBEAT.md`
- Version-control workspace standards in GitHub

## 6) Ongoing Maintenance

- Log daily context in `memory/YYYY-MM-DD.md`
- Curate important long-term facts into `MEMORY.md`
- Keep templates updated, then sync downstream instances
