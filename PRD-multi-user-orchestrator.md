# PRD: Orchestrator-Driven Multi-User OpenClaw Setup (EC2)

## Problem
Running multiple OpenClaw accounts on one EC2 host is currently ad-hoc, hard to audit, and risky when using unrestricted shell commands.

## Delivery Process Intent (Ralph PRD + Ralph Loop)
- Plan changes in PRD first, then implement docs/scripts in small deterministic increments.
- Use Ralph loop when stable in environment; if tool instability occurs, execute direct implementation while preserving PRD intent and documenting blocker in PR notes.
- Keep PRD, skill contract, runbook, and wrapper behavior in lockstep.

## Goal
Provide a deterministic, root-owned orchestration pattern to manage multiple OS-user OpenClaw accounts safely.

## Option A + C Hybrid Onboarding (target)
- **Option A (automated provisioning):** OS user setup, workspace bootstrap, deterministic service wiring.
- **Option C (guided checkpoints):** explicit pause points for interactive auth that cannot be safely automated (Slack OAuth + CLI auth).
- **Hybrid behavior:** `add_user` provisions and then pauses at checkpoint(s). Operator performs approved fixed command template(s), then runs `resume ... DONE` to continue.

## Scope (MVP)
- Add root-owned wrapper command for lifecycle actions:
  - `add`, `add_user`, `resume`, `list`, `status`, `restart`, `disable`, `remove`
- Add chat-facing skill layer for safe Telegram invocation with explicit magic trigger phrase.
- Restrict managed usernames by explicit allowlist policy.
- Avoid arbitrary shell passthrough (fixed subcommands only).
- Add append-only audit logging for all lifecycle actions + onboarding phase transitions.
- Add deterministic onboarding state files per user with pause/resume checkpoints.
- Add operator docs/runbook + skill docs with security constraints and exact command flow.
- Add validation script(s) for pause/resume/status transitions.

## Non-Goals
- Full IAM/SSO integration
- Remote fleet orchestration across hosts
- Dynamic plugin execution
- Arbitrary operator-defined shell steps at checkpoints

## Users
- Platform operator (root/sudo user) managing per-user OpenClaw instances.

## Inputs / Outputs

### Inputs
- CLI command + args (`add_user <username>`, `resume <username> <action>`, etc.)
- Policy file (`/etc/openclaw-orchestrator/policy.env` by default):
  - username allow regex
  - forbidden users list
  - service template
  - fixed checkpoint command templates
- Environment overrides for test/runtime (`ORCH_*` variables)

### Outputs
- Per-user lifecycle state file: `users/<username>.state`
- Per-user onboarding state file: `onboarding/<username>.state`
- Audit log record(s): `/var/log/openclaw-orchestrator/audit.log`
- Human-readable operator prompts at pause checkpoints

## State Machine (Onboarding)

Phases:
1. `provisioned` (internal transition after automated setup)
2. `waiting_slack_oauth` (pause)
3. `waiting_cli_auth` (pause)
4. `finalizing`
5. `complete`
6. `failed`

Allowed transitions:
- `add_user`:
  - none -> provisioned -> waiting_slack_oauth
- `resume DONE`:
  - waiting_slack_oauth -> waiting_cli_auth
  - waiting_cli_auth -> finalizing -> complete
- `resume RETRY`:
  - waiting_slack_oauth -> waiting_slack_oauth (retry_count++)
  - waiting_cli_auth -> waiting_cli_auth (retry_count++)
- `resume FAIL <reason>`:
  - waiting_slack_oauth|waiting_cli_auth -> failed

Invalid transitions fail closed and are audited.

## Guided Step Resume Model
- Operator receives exact checkpoint instruction and fixed command template.
- Wrapper never executes arbitrary operator text.
- Operator confirms progress explicitly with one of:
  - `resume <username> DONE`
  - `resume <username> RETRY [reason]`
  - `resume <username> FAIL <reason>`
- Resume command inspects persisted phase and enforces legal next steps.

## Failure / Retry Behavior
- `RETRY` increments retry counter and reprints current checkpoint instructions.
- `FAIL` marks onboarding state as failed and sets user state to `onboarding_failed`.
- Failed onboarding can be reattempted by re-running `add_user` after operator review (policy + auth root cause).
- Every retry/failure/transition emits audit log entry.

## Functional Requirements
1. **Managed user policy**
   - Wrapper must read allowed username pattern and explicit deny list.
   - Reject usernames that are empty, root/system users, or outside policy.
2. **Lifecycle commands**
   - `add <username>`: legacy one-step mode (backward-compatible)
   - `add_user <username>`: staged hybrid onboarding
   - `resume <username> <DONE|RETRY|FAIL>`: continue staged onboarding
   - `list`: show all managed users + onboarding phase summary
   - `status [username]`: show orchestrator + per-user service state + onboarding state
   - `restart <username|--all>`: restart managed service(s)
   - `disable <username>`: disable service and mark disabled
   - `remove <username>`: remove managed service and optional user assets (safe mode default keeps data)
3. **No arbitrary commands**
   - Unknown subcommands fail with usage output.
   - No raw command forwarding to shell.
4. **Audit log**
   - Log timestamp, actor, command, target user, outcome, reason/detail.
   - Include phase-transition records.
5. **Determinism/safe defaults**
   - Stable state directory for managed metadata.
   - Idempotent operations where possible.
   - Explicit `--force` required for destructive remove mode.
6. **Skill-layer execution contract (Telegram)**
   - Execution requires explicit magic phrase: `USERCTL LIFECYCLE`.
   - Parse only supported command grammar and arguments from SKILL.md.
   - Fail closed on ambiguity, unknown flags, or out-of-scope requests.
   - Require explicit confirmation before mutating operations.
   - Require double confirmation for destructive remove mode (`--force-delete`, optional `--purge-home`).

## Technical Approach
- `scripts/openclaw-orchestrator-userctl.sh` (bash strict mode).
- State root: `/var/lib/openclaw-orchestrator` (override via env for tests).
- Onboarding state root: `/var/lib/openclaw-orchestrator/onboarding`.
- Log file: `/var/log/openclaw-orchestrator/audit.log` (override via env).
- Fixed checkpoint command templates from policy file.
- Integrate with `openclaw gateway` lifecycle via fixed command map.

## Security Guardrails
- Hard-coded forbidden usernames (`root`, `ec2-user`, `nobody`, etc.).
- Username regex allowlist configurable in policy file.
- Reject non-root mutating operations unless explicit test override.
- Fixed command templates only for guided auth checkpoints.
- Quote all expansions; strict `set -euo pipefail`.
- Append-only audit log semantics.

## Acceptance Criteria
- Commands behave deterministically and return meaningful exit codes.
- Policy violations are rejected and audited.
- No subcommand can execute arbitrary shell text.
- Pause/resume onboarding works across process restarts via persisted state files.
- All onboarding phase transitions are audited.
- Docs include install, command flow, and recovery notes.
- Validation script passes locally in dry-run simulation.

## Test Plan
- `scripts/validate-orchestrator-userctl.sh` validates:
  - invalid username rejected
  - forbidden username rejected
  - unknown command rejected
  - `add_user` pause at Slack checkpoint
  - `resume RETRY` increments retry count
  - `resume DONE` transitions across checkpoints and completes
  - `resume FAIL` marks failed
  - remove archives both lifecycle and onboarding state in safe mode
  - audit log contains phase transition records

## Deliverables
- Updated wrapper script + policy template
- Updated PRD/runbook/README for hybrid onboarding + magic trigger phrase
- New skill doc: `skills/openclaw-userctl/SKILL.md` with deterministic command grammar
- Validation script covering pause/resume + state transitions
