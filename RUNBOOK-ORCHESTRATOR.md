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

## Prerequisites

### Slack App Setup (required before onboarding Slack users)
Complete these steps at https://api.slack.com/apps **before** running `add_user`:

1. **Create app** → From scratch → give it a name + workspace
2. **Enable Socket Mode** → App Settings → Socket Mode → toggle On → generate App Token with scope `connections:write` → copy `xapp-...` token
3. **OAuth & Permissions** → Add Bot Token Scopes:
   - `chat:write`
   - `im:read`
   - `im:write`
   - `channels:read`
   - `users:read`
4. **Install to Workspace** → copy `xoxb-...` Bot Token
5. **App Home** → Messages Tab → enable → check **"Allow users to send Slash commands and messages from the messages tab"**

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
- Ensures `openclaw` is in PATH for all users (FIX: symlink + permissions)
- Creates OS user if needed (`useradd`)
- Enables systemd lingering for the user
- Runs `openclaw setup` for the new user
- Creates system-level service file at `/etc/systemd/system/openclaw-gateway@<user>.service`
- Assigns gateway port: `GATEWAY_PORT_BASE + (uid % 1000)`

### Command sequence (operator exact flow)
1. Start staged onboarding:
   - `sudo openclaw-userctl add_user oc_alice`
2. Script pauses at **Slack config checkpoint** and prints token instructions.
3. Operator configures Slack tokens for the user:
   - `sudo -iu oc_alice openclaw config set channels.slack.botToken "xoxb-..."`
   - `sudo -iu oc_alice openclaw config set channels.slack.appToken "xapp-..."`
4. Operator confirms:
   - `sudo openclaw-userctl resume oc_alice DONE`
5. Script pauses at **health check checkpoint**.
6. Operator verifies the gateway is up and Slack is connected:
   - `sudo -iu oc_alice openclaw health`
   - Expected output includes: `Slack: ok`
7. Operator confirms:
   - `sudo openclaw-userctl resume oc_alice DONE`
8. Script finalizes (idempotent: skips enable/restart if service already active) and marks onboarding complete.

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
