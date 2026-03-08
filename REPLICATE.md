# Replicate Exact MVP v1 on a New OpenClaw Instance

This repo now supports deterministic replication via scripts.

## 1) Clone repo on target machine

```bash
git clone https://github.com/iamsteveng/openclaw-agent-swarm.git
cd openclaw-agent-swarm
```

## 2) Apply MVP v1 template to target OpenClaw workspace

```bash
chmod +x scripts/*.sh
./scripts/apply-mvp-v1.sh /path/to/.openclaw/workspace
```

This writes/overwrites exact MVP core files:

- AGENTS.md
- SOUL.md
- USER.md
- TOOLS.md
- MEMORY.md
- HEARTBEAT.md
- MVP-V1.md

And also:

- Creates `memory/` and `memory/YYYY-MM-DD.md` if missing
- Creates `.mvp-v1-manifest.json`
- Backs up overwritten files to `.mvp-v1-backups/<timestamp>/`

## 3) Verify exactness

```bash
./scripts/verify-mvp-v1.sh /path/to/.openclaw/workspace
```

You should see `OK` for all core files and final `VERIFIED`.

## 4) Customize only user-specific fields

Edit after apply:

- `USER.md` (name/timezone/preferences)
- `TOOLS.md` (machine-specific notes)

If you customize these, verification will show `DRIFT` for those files by design.

## 5) Operational note

`MVP-V1.md` is the authoritative orchestration contract.
`AGENTS.md` enforces runtime behavior in day-to-day execution.
