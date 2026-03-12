# Runbook: OpenClaw Multi-User Orchestrator (userctl)

## Purpose
Operate multiple OS-user OpenClaw accounts on one EC2 host with deterministic lifecycle commands and security guardrails.

## Components
- Wrapper: `scripts/openclaw-orchestrator-userctl.sh`
- Installed command path: `/usr/local/sbin/openclaw-userctl`
- Skill contract: `skills/openclaw-userctl/SKILL.md`
- Policy template: `scripts/orchestrator-policy.env.example`
- Validation: `scripts/validate-orchestrator-userctl.sh`

## Security Constraints
- Wrapper supports fixed subcommands only (`add/add_user/resume/list/status/restart/disable/remove`).
- No arbitrary shell passthrough.
- Username policy enforcement:
  - allowlist regex
  - explicit deny list
- Mutating commands require root (unless explicit test override).
- Audit logging for all commands, outcomes, and onboarding phase transitions.
- Guided checkpoints use fixed command templates only.
- Safe default remove mode archives orchestrator state/workspace metadata unless `--force-delete` is used.

## Telegram Skill Trigger (Magic Phrase)
For chat-driven execution, require exact trigger phrase:
- `USERCTL LIFECYCLE`

Execution policy from `skills/openclaw-userctl/SKILL.md`:
- no trigger phrase -> reject
- unknown/ambiguous/out-of-scope request -> reject
- mutating commands -> explicit confirmation
- destructive remove flags (`--force-delete`, `--purge-home`) -> double confirmation

## Architecture: One Slack App Per User

Each team member gets their **own dedicated Slack app** (individual bot), connected to their own OS user gateway. This is by design — see `DESIGN-DECISIONS.md` for full rationale.

**Why not a shared Slack bot?** Slack Socket Mode is outbound-only (gateway → Slack WebSocket). There is no inbound HTTP endpoint to proxy. A shared bot with per-user routing would require reimplementing OpenClaw's Slack internals — fragile and unsupported. Individual bots are simpler, more isolated, and more resilient.

The `add_user` checkpoint prints a pre-filled **Slack app manifest** you can import in one step — no manual scope configuration needed.

## Prerequisites

### openclaw binary (auto-handled by script)
The `add_user` command automatically ensures `/usr/local/bin/openclaw` is symlinked and world-executable. Manual fix if needed:
```bash
sudo ln -sf /home/ubuntu/.npm-global/bin/openclaw /usr/local/bin/openclaw
sudo chmod o+rx /usr/local/bin/openclaw
sudo chmod o+x /home/ubuntu/.npm-global /home/ubuntu/.npm-global/bin
```

### openclaw binary (auto-handled by script)
The `add_user` command automatically ensures `/usr/local/bin/openclaw` is symlinked and world-executable. Manual fix if needed:
```bash
sudo ln -sf /home/ubuntu/.npm-global/bin/openclaw /usr/local/bin/openclaw
sudo chmod o+rx /usr/local/bin/openclaw
sudo chmod o+x /home/ubuntu/.npm-global /home/ubuntu/.npm-global/bin
```

## Install (recommended)
1. Copy script to root-owned path:
   - `sudo install -o root -g root -m 0750 scripts/openclaw-orchestrator-userctl.sh /usr/local/sbin/openclaw-userctl`
2. Create policy directory and file:
   - `sudo mkdir -p /etc/openclaw-orchestrator`
   - `sudo cp scripts/orchestrator-policy.env.example /etc/openclaw-orchestrator/policy.env`
   - `sudo chown root:root /etc/openclaw-orchestrator/policy.env`
   - `sudo chmod 0640 /etc/openclaw-orchestrator/policy.env`
3. Review and edit `/etc/openclaw-orchestrator/policy.env` — set `ORCH_OPENCLAW_BIN` to your actual openclaw path.
4. Ensure state/log directories:
   - `/var/lib/openclaw-orchestrator`
   - `/var/log/openclaw-orchestrator`

## Hybrid Onboarding Flow (Option A + C)

### What `add_user` does automatically
- Ensures `openclaw` is in PATH for all users (symlink + permissions)
- Creates OS user if needed (`useradd`)
- Enables systemd lingering for the user
- Runs `openclaw setup` for the new user
- Applies MVP workspace template (`apply-mvp-v1.sh`) to user's workspace
- Creates system-level service file at `/etc/systemd/system/openclaw-gateway@<user>.service`
- Assigns gateway port: `GATEWAY_PORT_BASE + (uid % 1000)`
- Prints a pre-filled Slack app manifest for one-step app creation

### Command sequence (operator exact flow)
1. Start staged onboarding:
   - `sudo openclaw-userctl add_user oc_alice`
   - Script provisions user, applies workspace template, creates service file, prints Slack manifest
2. **Customize USER.md** for the new user:
   - Edit `/home/oc_alice/.openclaw/workspace/USER.md` with Alice's name, role, Slack user ID
3. Script pauses at **Slack config checkpoint** and prints:
   - A pre-filled Slack app manifest (import at https://api.slack.com/apps → Create → From manifest)
   - Instructions to generate the App Token (Socket Mode)
   - The exact config commands to run
4. Operator creates the Slack app via manifest import, then configures tokens:
   - `sudo -iu oc_alice openclaw config set channels.slack.botToken "xoxb-..."`
   - `sudo -iu oc_alice openclaw config set channels.slack.appToken "xapp-..."`
5. Operator confirms:
   - `sudo openclaw-userctl resume oc_alice DONE`
6. Script pauses at **health check checkpoint**.
7. Operator verifies the gateway is up and Slack is connected:
   - `sudo -iu oc_alice openclaw health`
   - Expected output includes: `Slack: ok`
8. Operator confirms:
   - `sudo openclaw-userctl resume oc_alice DONE`
9. Script finalizes (idempotent: skips enable/restart if service already active) and marks onboarding complete.

### Retry / failure controls
- Retry current checkpoint:
  - `sudo openclaw-userctl resume oc_alice RETRY "oauth popup closed"`
- Mark failed with reason:
  - `sudo openclaw-userctl resume oc_alice FAIL "token rejected"`

### Status checks
- Full status:
  - `sudo openclaw-userctl status`
- Per-user status (includes onboarding phase/status/retries):
  - `sudo openclaw-userctl status oc_alice`
- List users with onboarding summary:
  - `sudo openclaw-userctl list`

## Legacy and lifecycle commands
- Legacy one-step add (also creates service file automatically):
  - `sudo openclaw-userctl add oc_alice`
- Restart one:
  - `sudo openclaw-userctl restart oc_alice`
- Restart all:
  - `sudo openclaw-userctl restart --all`
- Disable:
  - `sudo openclaw-userctl disable oc_alice`
- Remove with safe archive-first default:
  - `sudo openclaw-userctl remove oc_alice`
- Force-remove OS user (destructive):
  - `sudo openclaw-userctl remove oc_alice --force-delete --purge-home`

## Audit Log
Default: `/var/log/openclaw-orchestrator/audit.log`

Log record fields:
- timestamp (UTC)
- actor
- command
- target user
- outcome (`ok|deny|fail`)
- detail

Includes `cmd=phase_transition` records for onboarding state machine moves.

## Validation (non-root dry run)
`./scripts/validate-orchestrator-userctl.sh`

## Operational Notes
- The wrapper creates system-level service files at `/etc/systemd/system/openclaw-gateway@<username>.service`.
- Override binary path, symlink, port base, and health check template in policy.
- Finalize step is idempotent: if the service is already running, enable/restart is skipped.
- Recover onboarding from `/var/lib/openclaw-orchestrator/onboarding/*.state` and audit log.
- After add_user: the gateway service starts automatically. Slack won't connect until tokens are configured at the Slack checkpoint.
