# Runbook: OpenClaw Multi-User Orchestrator (userctl)

## Purpose
Operate multiple OS-user OpenClaw accounts on one EC2 host with deterministic lifecycle commands and security guardrails.

## Components
- Wrapper: `scripts/openclaw-orchestrator-userctl.sh`
- Policy template: `scripts/orchestrator-policy.env.example`
- Validation: `scripts/validate-orchestrator-userctl.sh`

## Security Constraints
- Wrapper supports fixed subcommands only (`add/list/status/restart/disable/remove`).
- No arbitrary shell passthrough.
- Username policy enforcement:
  - allowlist regex
  - explicit deny list
- Mutating commands require root (unless explicit test override).
- Audit logging for all commands and outcomes.
- Safe default remove mode archives orchestrator state/workspace metadata unless `--force-delete` is used.

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

## Command Examples
- Add user:
  - `sudo openclaw-userctl add oc_alice`
- List users:
  - `sudo openclaw-userctl list`
- Status (all):
  - `sudo openclaw-userctl status`
- Status (single):
  - `sudo openclaw-userctl status oc_alice`
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

## Validation (non-root dry run)
`./scripts/validate-orchestrator-userctl.sh`

## Operational Notes
- The wrapper expects systemd unit template: `openclaw-agent@<username>.service` by default.
- Override service template in policy if your host uses a different unit naming convention.
- For recovery, reconstruct registry from `/var/lib/openclaw-orchestrator/users/*.state` and audit log.
