---
name: openclaw-userctl
description: Safe Telegram-triggered lifecycle control for managed OpenClaw OS users via fixed openclaw-userctl commands.
---

# SKILL: openclaw-userctl lifecycle orchestration (Telegram-safe)

## Purpose
This skill is the **only** chat-facing interface for managed OpenClaw user lifecycle operations.
It maps constrained natural-language requests into fixed commands for:
- `/usr/local/sbin/openclaw-userctl`

It exists to keep Telegram-triggered operations deterministic, auditable, and non-shell-injectable.

---

## Magic Trigger Phrase (required)
**`USERCTL LIFECYCLE`**

The assistant MUST only invoke this skill when the message includes the exact phrase `USERCTL LIFECYCLE` (case-insensitive).

If the phrase is absent, the assistant must refuse execution and ask the user to restate using the trigger phrase.

---

## In-Scope Actions
Mapped to fixed subcommands only:
- `add`
- `add_user`
- `resume`
- `list`
- `status`
- `restart`
- `disable`
- `remove`

No arbitrary shell, no extra subcommands, no command chaining.

---

## Command Catalog (what each command is for, and when to use)

### `add <username>`
- **For:** Immediate legacy add flow (non-staged provisioning path).
- **Use when:** You need backward-compatible behavior and do not need guided pause/resume checkpoints.

### `add_user <username>`
- **For:** Staged hybrid onboarding (Option A + C): auto provisioning + guided checkpoint flow.
- **Use when:** Onboarding a new teammate end-to-end via orchestrator with Slack/CLI checkpoint confirmations.

### `resume <username> <DONE|RETRY|FAIL> [reason...]`
- **For:** Advancing or controlling a paused staged onboarding.
- **Use when:** A checkpoint prompt has been issued and you are confirming completion (`DONE`), retrying (`RETRY`), or terminating (`FAIL`).

### `list`
- **For:** Showing managed users under orchestrator control.
- **Use when:** You need a quick inventory of provisioned users and their high-level state.

### `status [username]`
- **For:** Reading lifecycle and service status.
- **Use when:** You want current onboarding/service state for all users or one specific user.

### `restart <username>` / `restart --all`
- **For:** Restarting one or all managed OpenClaw user services.
- **Use when:** After config updates, failed health checks, or operational recovery.

### `disable <username>`
- **For:** Stopping and disabling a user’s service without full removal.
- **Use when:** Temporarily offboarding or suspending access while preserving user state.

### `remove <username> [--force-delete] [--purge-home]`
- **For:** Offboarding/removal of a managed user.
- **Use when:** You want to retire an account; default is safe/archival behavior, destructive cleanup only with explicit force flags.

---

## Natural-Language Trigger Patterns
Examples the parser may accept **only when magic phrase is present**:
- `USERCTL LIFECYCLE add user oc_alice`
- `USERCTL LIFECYCLE staged add_user oc_alice`
- `USERCTL LIFECYCLE resume oc_alice DONE`
- `USERCTL LIFECYCLE resume oc_alice RETRY reason oauth popup closed`
- `USERCTL LIFECYCLE resume oc_alice FAIL reason token rejected`
- `USERCTL LIFECYCLE status oc_alice`
- `USERCTL LIFECYCLE list`
- `USERCTL LIFECYCLE restart oc_alice`
- `USERCTL LIFECYCLE restart --all`
- `USERCTL LIFECYCLE disable oc_alice`
- `USERCTL LIFECYCLE remove oc_alice`
- `USERCTL LIFECYCLE remove oc_alice --force-delete --purge-home`

If parsing is ambiguous, assistant must ask a clarifying question and do nothing.

---

## Argument Parsing Contract

### Username
- Required for: `add`, `add_user`, `resume`, `status <username>`, `restart <username>`, `disable`, `remove`
- Must match policy regex (default): `^oc_[a-z0-9_]{2,24}$`
- Must not be forbidden user (e.g., `root`, `ec2-user`, `nobody`, `daemon`, `bin`, `sys`)

### Resume action
- Format: `resume <username> <DONE|RETRY|FAIL> [reason...]`
- `DONE`, `RETRY`, `FAIL` are uppercase canonical values.
- If user types lowercase, normalize to uppercase before command generation.

### Restart target
- Must be exactly one of:
  - `restart <username>`
  - `restart --all`

### Remove flags
- Allowed only:
  - `--force-delete` (alias `--force` accepted by script)
  - `--purge-home`
- Reject any unknown flag.
- Safety recommendation at skill layer: use `--purge-home` only with `--force-delete`.

---

## Deterministic Command Mapping
Use absolute executable path:

- `add <u>` -> `/usr/local/sbin/openclaw-userctl add <u>`
- `add_user <u>` -> `/usr/local/sbin/openclaw-userctl add_user <u>`
- `resume <u> <ACTION> [reason]` -> `/usr/local/sbin/openclaw-userctl resume <u> <ACTION> [reason]`
- `list` -> `/usr/local/sbin/openclaw-userctl list`
- `status` -> `/usr/local/sbin/openclaw-userctl status`
- `status <u>` -> `/usr/local/sbin/openclaw-userctl status <u>`
- `restart <u>` -> `/usr/local/sbin/openclaw-userctl restart <u>`
- `restart --all` -> `/usr/local/sbin/openclaw-userctl restart --all`
- `disable <u>` -> `/usr/local/sbin/openclaw-userctl disable <u>`
- `remove <u>` -> `/usr/local/sbin/openclaw-userctl remove <u>`
- `remove <u> --force-delete` -> `/usr/local/sbin/openclaw-userctl remove <u> --force-delete`
- `remove <u> --force-delete --purge-home` -> `/usr/local/sbin/openclaw-userctl remove <u> --force-delete --purge-home`

The assistant must not emit or run any command not in this mapping.

---

## Safety + Confirmation Rules
1. **Magic phrase required** (`USERCTL LIFECYCLE`).
2. **Dry parse first**: echo parsed intent before execution for mutating operations.
3. **Explicit confirmation required** before mutating commands:
   - mutating: `add`, `add_user`, `resume`, `restart`, `disable`, `remove`
   - read-only: `list`, `status`
4. **High-risk double confirmation** required for:
   - `remove ... --force-delete`
   - `remove ... --force-delete --purge-home`
   Confirmation text must include username and destructive flags.
5. **Fail closed**:
   - missing/invalid username
   - invalid resume action
   - unknown flags
   - out-of-scope request
   -> reject with reason and do not run command.

---

## Explicit Rejection Behavior
Reject requests that are not lifecycle control for managed users, including:
- running arbitrary shell (`run this script`, `execute this command`, pipes, redirects)
- editing policy files via chat
- user password changes / SSH key management
- package installation / host hardening / IAM changes
- direct systemctl commands outside mapped wrapper
- data exfiltration or secret retrieval

Standard rejection format:
1. `Rejected: out of scope for USERCTL LIFECYCLE skill.`
2. brief reason
3. accepted command shapes

---

## What This Skill Is NOT For
- General Linux administration
- Arbitrary OpenClaw CLI operations
- Debug shell access
- Bypassing root/sudo/audit constraints
- Fleet/remote host orchestration

---

## Examples

### Valid
- `USERCTL LIFECYCLE add_user oc_maria`
- `USERCTL LIFECYCLE resume oc_maria DONE`
- `USERCTL LIFECYCLE resume oc_maria RETRY reason browser auth interrupted`
- `USERCTL LIFECYCLE status`
- `USERCTL LIFECYCLE restart --all`
- `USERCTL LIFECYCLE remove oc_maria`

### Rejected
- `add_user oc_maria` (missing magic phrase)
- `USERCTL LIFECYCLE add_user Maria` (invalid username policy)
- `USERCTL LIFECYCLE resume oc_maria SKIP`
- `USERCTL LIFECYCLE remove oc_maria --delete-now`
- `USERCTL LIFECYCLE run 'systemctl daemon-reload && ...'`
- `USERCTL LIFECYCLE edit /etc/openclaw-orchestrator/policy.env`
