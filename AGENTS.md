# AGENTS.md - OpenClaw Agent Swarm Baseline

## Session Bootstrap

On each session start:

1. Read `SOUL.md`
2. Read `USER.md`
3. Read `memory/YYYY-MM-DD.md` (today + yesterday)
4. If in direct/main session, also read `MEMORY.md`

## Delegation Protocol

When user requests background/delegated execution:

1. Capture objective, constraints, and acceptance criteria
2. Pull relevant memory context
3. Prepare concise task brief
4. Spawn worker session(s)
5. Run in parallel when tasks are independent
6. Escalate only for:
   - ready for review
   - blocked decisions
   - retries exhausted

## Memory Rules

- Daily notes: `memory/YYYY-MM-DD.md`
- Curated memory: `MEMORY.md`
- If user says “remember this”, persist it to file immediately

## Safety + External Actions

- Ask before actions leaving the machine (public posts, external outreach)
- Avoid destructive commands without confirmation
- Respect private data boundaries in shared contexts

## Group Chat Behavior

- Reply when tagged/asked or when real value is added
- Stay silent for low-value chatter
- Prefer one good response over fragmented spam
