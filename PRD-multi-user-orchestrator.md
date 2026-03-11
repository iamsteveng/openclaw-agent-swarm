# PRD: Orchestrator-Driven Multi-User OpenClaw Setup (EC2)

## Problem
Running multiple OpenClaw accounts on one EC2 host is currently ad-hoc, hard to audit, and risky when using unrestricted shell commands.

## Goal
Provide a deterministic, root-owned orchestration pattern to manage multiple OS-user OpenClaw accounts safely.

## Scope (MVP)
- Add root-owned wrapper command for lifecycle actions:
  - `add`, `list`, `status`, `restart`, `disable`, `remove`
- Restrict managed usernames by explicit allowlist policy.
- Avoid arbitrary shell passthrough (fixed subcommands only).
- Add append-only audit logging for all lifecycle actions.
- Add safe defaults (disabled-by-default on create optional, explicit confirmation gates).
- Add operator docs/runbook with security constraints.
- Add validation script(s) for command routing and policy enforcement.

## Non-Goals
- Full IAM/SSO integration
- Remote fleet orchestration across hosts
- Dynamic plugin execution

## Users
- Platform operator (root/sudo user) managing per-user OpenClaw instances.

## Functional Requirements
1. **Managed user policy**
   - Wrapper must read allowed username pattern and explicit deny list.
   - Reject usernames that are empty, root/system users, or outside policy.
2. **Lifecycle commands**
   - `add <username>`: create/manage user workspace and service template state.
   - `list`: show all managed users and enabled/disabled state.
   - `status [username]`: show orchestrator + per-user service state.
   - `restart <username|--all>`: restart managed service(s).
   - `disable <username>`: disable service and mark disabled.
   - `remove <username>`: remove managed service and optional user assets (safe mode default keeps data).
3. **No arbitrary commands**
   - Unknown subcommands fail with usage output.
   - No raw command forwarding to shell.
4. **Audit log**
   - Log timestamp, actor, command, target user, outcome, reason (on failure).
   - File path deterministic and root-writable only.
5. **Determinism/safe defaults**
   - Stable state directory for managed metadata.
   - Idempotent operations where possible.
   - Explicit `--force` required for destructive remove mode.

## Technical Approach
- Introduce `scripts/openclaw-orchestrator-userctl` (bash, strict mode).
- State root: `/var/lib/openclaw-orchestrator` (override for tests via env).
- Log file: `/var/log/openclaw-orchestrator/audit.log` (override for tests via env).
- Managed users registry in deterministic flat-file or directory entries.
- Integrate with `openclaw gateway` lifecycle via fixed command map.

## Security Guardrails
- Hard-coded forbidden usernames (`root`, `ec2-user`, `nobody`, etc.).
- Username regex allowlist (e.g. `^oc_[a-z0-9_]{2,24}$`) configurable in policy file.
- Reject if not run as root for mutating commands.
- Quote all expansions; strict `set -euo pipefail`.
- Use absolute command paths when practical.

## Acceptance Criteria
- Commands behave deterministically and return meaningful exit codes.
- Policy violations are rejected and audited.
- No subcommand can execute arbitrary shell text.
- Docs include setup, examples, and recovery/safety notes.
- Validation script passes in local dry-run simulation.

## Test Plan
- `scripts/validate-orchestrator-userctl.sh`:
  - invalid username rejected
  - forbidden username rejected
  - add/list/status path works in temp state root
  - unknown command rejected
  - disable/remove state transitions logged

## Deliverables
- Wrapper script + helper library/policy file(s)
- Runbook docs
- Validation script
- README updates
