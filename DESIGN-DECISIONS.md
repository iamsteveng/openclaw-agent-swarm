# Design Decisions — OpenClaw Multi-User Orchestrator

This document records the key architectural decisions made during the initial deployment of the Loco multi-user OpenClaw setup, including the reasoning and alternatives considered.

---

## 1. OS-Level Isolation per User

**Decision:** Each team member gets their own Linux OS user account (`oc_<username>`), their own OpenClaw gateway process, and their own home directory.

**Why:** Workspace-level separation alone (different folders under one user) is not sufficient. Each user needs isolated:
- SSH keys
- CLI tool logins (GitHub, cloud providers, etc.)
- Environment variables and secrets
- Process-level separation

**Alternatives considered:**
- Single OS user + multiple agent workspaces via `agents.list` and `bindings` → rejected because it doesn't provide SSH/CLI isolation.

---

## 2. System-Level Systemd Services (not user-level)

**Decision:** Each user's gateway runs as a system-level `openclaw-gateway@<username>.service` managed by root, not as a `systemd --user` service.

**Why:** `sudo -iu <user>` shell sessions (used by the orchestrator) cannot access the user's systemd session bus. `loginctl enable-linger` helps but is unreliable in non-login sudo contexts on this EC2 setup. System-level services are more reliable and root-auditable.

**Tradeoff:** Users cannot manage their own service lifecycle without sudo.

---

## 3. One Slack App Per User (Individual Bots)

**Decision:** Each team member has their own Slack app with their own bot token, connected exclusively to their dedicated gateway.

**Context and reasoning:**

We explored three options:

### Option A: Individual Slack Apps ✅ (chosen)
- One Slack app per user → one bot token per user
- Each bot connects directly to that user's gateway (Socket Mode)
- Full OS isolation preserved
- If one user's bot breaks, others are unaffected
- Main downside: admin must create a Slack app per new user → mitigated by Slack manifest import (see below)

### Option B: Shared Slack Bot + Routing Proxy ❌ (rejected)
- One Slack app, one bot token shared across all users
- A custom routing proxy intercepts Socket Mode events and forwards to the right gateway by Slack User ID
- **Why rejected:**
  - Slack Socket Mode is an **outbound** WebSocket from the gateway to Slack — there is no inbound HTTP endpoint to proxy
  - OpenClaw gateways have no documented API to inject Slack events from an external source
  - Would require reimplementing OpenClaw's Slack provider internals — fragile and unsupported
  - Single point of failure: proxy downtime = everyone loses access
  - High implementation complexity for marginal UX gain

### Option C: Single Gateway + `agents.list` + `bindings` ❌ (rejected)
- One gateway, one Slack bot, multiple named agents, routing by Slack User ID via `bindings`
- Native OpenClaw support, no custom code
- **Why rejected:** All agents run under one OS user — no SSH/CLI/secret isolation. Violates core isolation requirement.

**User experience note:** Individual bots mean each person DMs *their own* personal assistant bot, not a shared company bot. This is actually a natural fit — it's their dedicated agent, not a shared inbox.

---

## 4. Slack App Creation via Manifest Import

**Decision:** Streamline per-user Slack app creation using Slack's manifest import feature. The `add_user` onboarding prints a pre-filled JSON manifest that the operator imports in one step at api.slack.com.

**Why:** Manual Slack app creation involves many steps (scopes, Socket Mode, App Home, events). A manifest reduces this to: go to api.slack.com → Create App → From manifest → paste → create.

---

## 5. Script Fixes Applied During Initial Deployment

Several issues were discovered during the first real `add_user` run (`oc_steveng`) and fixed in the script:

| Issue | Fix |
|-------|-----|
| `openclaw` not in PATH for new OS users | `ensure_openclaw_path()` auto-symlinks + fixes world-exec perms |
| Service template default `openclaw-agent@` doesn't exist | Changed default to `openclaw-gateway@%s.service` |
| No service file created during `add_user` | `create_system_service()` now creates it automatically |
| Slack checkpoint used nonexistent `openclaw auth slack` | Replaced with `openclaw config set channels.slack.botToken/appToken` |
| CLI configure checkpoint hangs interactively | Replaced with `openclaw health` verification |
| Finalize step fails if service already running | Made finalize idempotent |
| RUNBOOK missing Slack app prerequisites | Added full Slack app setup section |

---

## 6. OpenClaw Config Tuning (Admin Gateway)

Applied to the main ubuntu gateway:
- `compaction.reserveTokensFloor: 20000` — ensures enough token headroom before compaction
- `compaction.memoryFlush` — auto-writes memory notes when session nears compaction
- `contextPruning` (cache-ttl, 6h, keepLastAssistants: 3) — prunes old context to keep sessions lean
- `memorySearch.query.hybrid` — weighted hybrid search (70% vector, 30% text) for better memory recall

---

## 7. MVP Template Replication per User

**Decision:** Each user's workspace should be bootstrapped using `apply-mvp-v1.sh` from the `openclaw-agent-swarm` repo, with `USER.md` customised per person.

**Why:** The agent on `oc_steveng` needs to know it belongs to Steve (name, role, Slack user ID) so it can identify its owner when messages arrive. Without this, the agent has no identity context.

**Status:** Pending — `oc_steveng`'s workspace has not yet had the MVP template applied and `USER.md` customised with Steve's details and Slack user ID.

---

## Open Items

- [ ] Apply MVP template to `oc_steveng`'s workspace, populate `USER.md` with Steve's Slack user ID
- [ ] Automate Slack manifest generation in `add_user` checkpoint output
- [ ] Define trust levels for future colleagues (admin vs regular user)
- [ ] Document port allocation strategy as more users are added
