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

## Install (recommended)
1. Copy script to root-owned path:
   - `sudo install -o root -g root -m 0750 scripts/openclaw-orchestrator-userctl.sh /usr/local/sbin/openclaw-userctl`
2. Create policy directory and file:
   - `sudo mkdir -p /etc/openclaw-orchestrator`
   - `sudo cp scripts/orchestrator-policy.env.example /etc/openclaw-orchestrator/policy.env`
   - `sudo chown root:root /etc/openclaw-orchestrator/policy.env`
   - `sudo chmod 0640 /etc/openclaw-orchestrator/policy.env`
3. Ensure state/log directories:
   - `/var/lib/openclaw-orchestrator`
   - `/var/log/openclaw-orchestrator`

## Hybrid Onboarding Flow (Option A + C)

### Command sequence (operator exact flow)
1. Start staged onboarding:
   - `sudo openclaw-userctl add_user oc_alice`
2. Script pauses at Slack OAuth checkpoint and prints the fixed command template.
3. Operator runs the printed Slack auth command, then resumes:
   - `sudo openclaw-userctl resume oc_alice DONE`
4. Script pauses at CLI auth checkpoint and prints the fixed command template.
5. Operator runs the printed CLI auth command, then resumes:
   - `sudo openclaw-userctl resume oc_alice DONE`
6. Script finalizes service enable/restart and marks onboarding complete.

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
- Legacy one-step add:
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
- The wrapper expects systemd unit template: `openclaw-agent@<username>.service` by default.
- Override service template/checkpoint templates in policy if your host differs.
- Recover onboarding from `/var/lib/openclaw-orchestrator/onboarding/*.state` and audit log.
