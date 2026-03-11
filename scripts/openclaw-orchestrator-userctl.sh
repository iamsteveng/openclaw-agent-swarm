#!/usr/bin/env bash
set -euo pipefail

# openclaw-orchestrator-userctl.sh
# Deterministic lifecycle wrapper for managed OpenClaw OS users.
# Option A + C hybrid onboarding:
# - automated provisioning
# - guided pause/resume checkpoints for interactive auth

STATE_ROOT="${ORCH_STATE_ROOT:-/var/lib/openclaw-orchestrator}"
USERS_DIR="$STATE_ROOT/users"
ONBOARDING_DIR="$STATE_ROOT/onboarding"
ARCHIVE_DIR="$STATE_ROOT/archive"
WORKSPACES_DIR="$STATE_ROOT/workspaces"
LOG_DIR="${ORCH_LOG_DIR:-/var/log/openclaw-orchestrator}"
AUDIT_LOG="$LOG_DIR/audit.log"
POLICY_FILE="${ORCH_POLICY_FILE:-/etc/openclaw-orchestrator/policy.env}"
ALLOW_REGEX="${ORCH_ALLOW_REGEX:-^oc_[a-z0-9_]{2,24}$}"
FORBIDDEN_USERS_DEFAULT="root ec2-user nobody daemon bin sys"
SERVICE_TEMPLATE="${ORCH_SERVICE_TEMPLATE:-openclaw-agent@%s.service}"
SLACK_OAUTH_CMD_TEMPLATE="${ORCH_SLACK_OAUTH_CMD_TEMPLATE:-sudo -iu %s openclaw auth slack}"
CLI_AUTH_CMD_TEMPLATE="${ORCH_CLI_AUTH_CMD_TEMPLATE:-sudo -iu %s openclaw auth login}"
DRY_RUN="${ORCH_DRY_RUN:-0}"

MUTATING_COMMANDS=" add add_user resume restart disable remove "

PHASE_PROVISIONED="provisioned"
PHASE_WAIT_SLACK="waiting_slack_oauth"
PHASE_WAIT_CLI="waiting_cli_auth"
PHASE_FINALIZING="finalizing"
PHASE_COMPLETE="complete"
PHASE_FAILED="failed"

load_policy() {
  if [[ -f "$POLICY_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$POLICY_FILE"
  fi
  ALLOW_REGEX="${ORCH_ALLOW_REGEX:-$ALLOW_REGEX}"
  FORBIDDEN_USERS="${ORCH_FORBIDDEN_USERS:-$FORBIDDEN_USERS_DEFAULT}"
  SERVICE_TEMPLATE="${ORCH_SERVICE_TEMPLATE:-$SERVICE_TEMPLATE}"
  SLACK_OAUTH_CMD_TEMPLATE="${ORCH_SLACK_OAUTH_CMD_TEMPLATE:-$SLACK_OAUTH_CMD_TEMPLATE}"
  CLI_AUTH_CMD_TEMPLATE="${ORCH_CLI_AUTH_CMD_TEMPLATE:-$CLI_AUTH_CMD_TEMPLATE}"
}

usage() {
  cat <<'EOF'
Usage:
  openclaw-orchestrator-userctl.sh add <username>
  openclaw-orchestrator-userctl.sh add_user <username>
  openclaw-orchestrator-userctl.sh resume <username> <DONE|RETRY|FAIL> [reason]
  openclaw-orchestrator-userctl.sh list
  openclaw-orchestrator-userctl.sh status [username]
  openclaw-orchestrator-userctl.sh restart <username|--all>
  openclaw-orchestrator-userctl.sh disable <username>
  openclaw-orchestrator-userctl.sh remove <username> [--force-delete] [--purge-home]

Notes:
  - Fixed subcommands only; arbitrary shell passthrough is not supported.
  - Mutating commands require root unless ORCH_ALLOW_NON_ROOT=1.
  - add_user = staged onboarding with guided pause/resume checkpoints.
  - resume requires explicit DONE confirmation from operator.
  - Use ORCH_DRY_RUN=1 for no-op command execution in test environments.
EOF
}

ensure_dirs() {
  mkdir -p "$USERS_DIR" "$ONBOARDING_DIR" "$ARCHIVE_DIR" "$WORKSPACES_DIR" "$LOG_DIR"
  touch "$AUDIT_LOG"
  chmod 700 "$STATE_ROOT" "$USERS_DIR" "$ONBOARDING_DIR" || true
  chmod 750 "$LOG_DIR" || true
  chmod 640 "$AUDIT_LOG" || true
}

audit() {
  local outcome="$1" cmd="$2" target="${3:-}" detail="${4:-}"
  local actor
  actor="${SUDO_USER:-${USER:-unknown}}"
  printf '%s actor=%s cmd=%s target=%s outcome=%s detail=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$actor" "$cmd" "$target" "$outcome" "$detail" >> "$AUDIT_LOG"
}

require_root_if_mutating() {
  local cmd="$1"
  if [[ "$MUTATING_COMMANDS" == *" $cmd "* ]]; then
    if [[ "${EUID}" -ne 0 && "${ORCH_ALLOW_NON_ROOT:-0}" != "1" ]]; then
      audit "deny" "$cmd" "" "requires-root"
      echo "ERROR: '$cmd' requires root." >&2
      exit 2
    fi
  fi
}

valid_username() {
  local u="$1"
  [[ -n "$u" ]] || return 1
  [[ "$u" =~ $ALLOW_REGEX ]] || return 1
  for f in $FORBIDDEN_USERS; do
    [[ "$u" != "$f" ]] || return 1
  done
  return 0
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] $*"
    return 0
  fi
  "$@"
}

user_state_file() {
  local u="$1"
  echo "$USERS_DIR/$u.state"
}

onboarding_state_file() {
  local u="$1"
  echo "$ONBOARDING_DIR/$u.state"
}

is_managed_user() {
  local u="$1"
  [[ -f "$(user_state_file "$u")" ]]
}

set_user_state() {
  local u="$1" status="$2"
  cat > "$(user_state_file "$u")" <<EOF
username=$u
status=$status
updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

service_name_for() {
  local u="$1"
  printf "$SERVICE_TEMPLATE" "$u"
}

read_onboarding_state() {
  local u="$1"
  local f
  f="$(onboarding_state_file "$u")"
  [[ -f "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f"
}

write_onboarding_state() {
  local u="$1" phase="$2" status="$3" retries="$4" note="${5:-}"
  local esc_note
  printf -v esc_note '%q' "$note"
  cat > "$(onboarding_state_file "$u")" <<EOF
username=$u
phase=$phase
status=$status
retries=$retries
note=$esc_note
updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

transition_onboarding() {
  local u="$1" next_phase="$2" next_status="$3" retry_count="$4" reason="${5:-}"
  local cur_phase="none"
  local cur_status="none"
  if read_onboarding_state "$u"; then
    cur_phase="${phase:-none}"
    cur_status="${status:-none}"
  fi
  write_onboarding_state "$u" "$next_phase" "$next_status" "$retry_count" "$reason"
  audit "ok" "phase_transition" "$u" "from=${cur_phase}/${cur_status} to=${next_phase}/${next_status} reason=${reason}"
}

print_slack_checkpoint() {
  local u="$1"
  local cmd
  printf -v cmd "$SLACK_OAUTH_CMD_TEMPLATE" "$u"
  cat <<EOF
CHECKPOINT: Slack OAuth required for $u
Run EXACT command template:
  $cmd
Then confirm:
  sudo openclaw-userctl resume $u DONE
If it fails and you need to retry same step:
  sudo openclaw-userctl resume $u RETRY
EOF
}

print_cli_checkpoint() {
  local u="$1"
  local cmd
  printf -v cmd "$CLI_AUTH_CMD_TEMPLATE" "$u"
  cat <<EOF
CHECKPOINT: OpenClaw CLI auth required for $u
Run EXACT command template:
  $cmd
Then confirm:
  sudo openclaw-userctl resume $u DONE
If it fails and you need to retry same step:
  sudo openclaw-userctl resume $u RETRY
EOF
}

cmd_add_user() {
  local u="${1:-}"
  if ! valid_username "$u"; then
    audit "deny" "add_user" "$u" "invalid-username"
    echo "ERROR: invalid or forbidden username '$u'" >&2
    exit 3
  fi

  if read_onboarding_state "$u"; then
    if [[ "${phase:-}" != "$PHASE_COMPLETE" && "${phase:-}" != "$PHASE_FAILED" ]]; then
      audit "deny" "add_user" "$u" "onboarding-already-active phase=${phase:-unknown}"
      echo "ERROR: onboarding already active for '$u' at phase '${phase:-unknown}'. Use resume." >&2
      exit 7
    fi
  fi

  if ! id "$u" >/dev/null 2>&1; then
    run_cmd useradd --create-home --shell /bin/bash "$u"
  fi

  mkdir -p "$WORKSPACES_DIR/$u"
  set_user_state "$u" "pending_auth"

  transition_onboarding "$u" "$PHASE_PROVISIONED" "in_progress" 0 "provisioning-complete"
  transition_onboarding "$u" "$PHASE_WAIT_SLACK" "waiting_operator_action" 0 "awaiting-slack-oauth"

  audit "ok" "add_user" "$u" "provisioned-awaiting-slack"
  echo "Provisioning complete for $u."
  print_slack_checkpoint "$u"
}

cmd_resume() {
  local u="${1:-}"
  local action="${2:-}"
  shift 2 || true
  local reason="${*:-operator-update}"

  if [[ -z "$u" || -z "$action" ]]; then
    echo "ERROR: usage: resume <username> <DONE|RETRY|FAIL> [reason]" >&2
    exit 8
  fi
  if ! valid_username "$u"; then
    audit "deny" "resume" "$u" "invalid-username"
    echo "ERROR: invalid or forbidden username '$u'" >&2
    exit 3
  fi
  if ! read_onboarding_state "$u"; then
    audit "fail" "resume" "$u" "onboarding-state-missing"
    echo "ERROR: onboarding state missing for '$u'. Start with add_user." >&2
    exit 9
  fi

  local p="${phase:-}"
  local r="${retries:-0}"

  case "$action" in
    DONE)
      if [[ "$p" == "$PHASE_WAIT_SLACK" ]]; then
        transition_onboarding "$u" "$PHASE_WAIT_CLI" "waiting_operator_action" "$r" "slack-complete-awaiting-cli"
        audit "ok" "resume" "$u" "advanced-to-cli"
        print_cli_checkpoint "$u"
        return
      fi
      if [[ "$p" == "$PHASE_WAIT_CLI" ]]; then
        transition_onboarding "$u" "$PHASE_FINALIZING" "in_progress" "$r" "cli-complete-finalizing"
        run_cmd systemctl enable "$(service_name_for "$u")"
        run_cmd systemctl restart "$(service_name_for "$u")"
        set_user_state "$u" "enabled"
        transition_onboarding "$u" "$PHASE_COMPLETE" "done" "$r" "onboarding-complete"
        audit "ok" "resume" "$u" "completed"
        echo "Onboarding complete for $u"
        return
      fi
      audit "deny" "resume" "$u" "invalid-done-phase=$p"
      echo "ERROR: DONE is only valid in phases: $PHASE_WAIT_SLACK, $PHASE_WAIT_CLI (current: $p)" >&2
      exit 10
      ;;
    RETRY)
      if [[ "$p" != "$PHASE_WAIT_SLACK" && "$p" != "$PHASE_WAIT_CLI" ]]; then
        audit "deny" "resume" "$u" "invalid-retry-phase=$p"
        echo "ERROR: RETRY only valid at checkpoint phases (current: $p)" >&2
        exit 11
      fi
      r=$((r + 1))
      transition_onboarding "$u" "$p" "waiting_operator_action" "$r" "$reason"
      audit "ok" "resume" "$u" "retry phase=$p count=$r"
      if [[ "$p" == "$PHASE_WAIT_SLACK" ]]; then
        print_slack_checkpoint "$u"
      else
        print_cli_checkpoint "$u"
      fi
      ;;
    FAIL)
      transition_onboarding "$u" "$PHASE_FAILED" "failed" "$r" "$reason"
      set_user_state "$u" "onboarding_failed"
      audit "fail" "resume" "$u" "marked-failed reason=$reason"
      echo "Onboarding marked FAILED for $u: $reason"
      ;;
    *)
      audit "deny" "resume" "$u" "invalid-action=$action"
      echo "ERROR: invalid action '$action'. Use DONE, RETRY, or FAIL." >&2
      exit 12
      ;;
  esac
}

# Legacy single-step add kept for backwards compatibility.
cmd_add() {
  local u="${1:-}"
  if ! valid_username "$u"; then
    audit "deny" "add" "$u" "invalid-username"
    echo "ERROR: invalid or forbidden username '$u'" >&2
    exit 3
  fi

  if ! id "$u" >/dev/null 2>&1; then
    run_cmd useradd --create-home --shell /bin/bash "$u"
  fi

  mkdir -p "$WORKSPACES_DIR/$u"
  set_user_state "$u" "enabled"

  local svc
  svc="$(service_name_for "$u")"
  run_cmd systemctl enable "$svc"
  run_cmd systemctl restart "$svc"

  transition_onboarding "$u" "$PHASE_COMPLETE" "done" 0 "legacy-add-complete"
  audit "ok" "add" "$u" "created-or-updated"
  echo "Added/updated managed user: $u"
}

cmd_list() {
  shopt -s nullglob
  local found=0
  for f in "$USERS_DIR"/*.state; do
    found=1
    # shellcheck disable=SC1090
    source "$f"
    local ob_phase="none" ob_status="none"
    if read_onboarding_state "$username"; then
      ob_phase="${phase:-none}"
      ob_status="${status:-none}"
    fi
    printf '%s\t%s\t%s\tonboarding=%s/%s\n' "$username" "$status" "$updatedAt" "$ob_phase" "$ob_status"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No managed users."
  fi
  audit "ok" "list" "-" "listed"
}

cmd_status() {
  local u="${1:-}"
  if [[ -z "$u" ]]; then
    echo "gateway_status:"
    if command -v openclaw >/dev/null 2>&1; then
      run_cmd openclaw gateway status || true
    else
      echo "openclaw binary not found"
    fi
    echo
    echo "managed_users:"
    cmd_list
    return
  fi

  if ! is_managed_user "$u"; then
    audit "fail" "status" "$u" "not-managed"
    echo "ERROR: '$u' is not a managed user" >&2
    exit 4
  fi

  # shellcheck disable=SC1090
  source "$(user_state_file "$u")"
  local svc
  svc="$(service_name_for "$u")"
  echo "username: $username"
  echo "status: $status"
  echo "updatedAt: $updatedAt"
  echo "service: $svc"
  if read_onboarding_state "$u"; then
    echo "onboarding_phase: ${phase:-unknown}"
    echo "onboarding_status: ${status:-unknown}"
    echo "onboarding_retries: ${retries:-0}"
    echo "onboarding_note: ${note:-none}"
  fi
  run_cmd systemctl status "$svc" --no-pager || true
  audit "ok" "status" "$u" "queried"
}

cmd_restart() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "ERROR: restart requires <username|--all>" >&2
    exit 5
  fi

  if [[ "$target" == "--all" ]]; then
    shopt -s nullglob
    local f u svc
    for f in "$USERS_DIR"/*.state; do
      # shellcheck disable=SC1090
      source "$f"
      u="$username"
      svc="$(service_name_for "$u")"
      run_cmd systemctl restart "$svc"
      audit "ok" "restart" "$u" "all"
    done
    echo "Restarted all managed users"
    return
  fi

  local u="$target"
  if ! is_managed_user "$u"; then
    audit "fail" "restart" "$u" "not-managed"
    echo "ERROR: '$u' is not a managed user" >&2
    exit 4
  fi
  run_cmd systemctl restart "$(service_name_for "$u")"
  audit "ok" "restart" "$u" "single"
  echo "Restarted $u"
}

cmd_disable() {
  local u="${1:-}"
  if ! is_managed_user "$u"; then
    audit "fail" "disable" "$u" "not-managed"
    echo "ERROR: '$u' is not a managed user" >&2
    exit 4
  fi
  local svc
  svc="$(service_name_for "$u")"
  run_cmd systemctl disable --now "$svc"
  set_user_state "$u" "disabled"
  audit "ok" "disable" "$u" "disabled"
  echo "Disabled $u"
}

cmd_remove() {
  local u="${1:-}"
  shift || true
  local force=0 purge_home=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force|--force-delete) force=1 ;;
      --purge-home) purge_home=1 ;;
      *) echo "ERROR: unknown remove option '$1'" >&2; exit 6 ;;
    esac
    shift
  done

  if ! is_managed_user "$u"; then
    audit "fail" "remove" "$u" "not-managed"
    echo "ERROR: '$u' is not a managed user" >&2
    exit 4
  fi

  local svc state_file ob_state_file ts archive_prefix
  svc="$(service_name_for "$u")"
  state_file="$(user_state_file "$u")"
  ob_state_file="$(onboarding_state_file "$u")"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_prefix="$ARCHIVE_DIR/$u-$ts"

  run_cmd systemctl disable --now "$svc"

  if [[ "$force" -eq 1 ]]; then
    rm -f "$state_file" "$ob_state_file"
    if id "$u" >/dev/null 2>&1; then
      if [[ "$purge_home" -eq 1 ]]; then
        run_cmd userdel -r "$u"
      else
        run_cmd userdel "$u"
      fi
    fi
    audit "ok" "remove" "$u" "force-delete purge_home=$purge_home"
    echo "Removed $u (force-delete mode)"
  else
    mv "$state_file" "$archive_prefix.state"
    if [[ -f "$ob_state_file" ]]; then
      mv "$ob_state_file" "$archive_prefix.onboarding.state"
    fi
    if [[ -d "$WORKSPACES_DIR/$u" ]]; then
      mv "$WORKSPACES_DIR/$u" "$archive_prefix.workspace"
    fi
    audit "ok" "remove" "$u" "archived=$archive_prefix"
    echo "Archived and removed $u from active orchestrator state (safe default)."
  fi
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    usage
    exit 1
  fi

  load_policy
  ensure_dirs
  require_root_if_mutating "$cmd"

  shift || true
  case "$cmd" in
    add) cmd_add "$@" ;;
    add_user) cmd_add_user "$@" ;;
    resume) cmd_resume "$@" ;;
    list) cmd_list "$@" ;;
    status) cmd_status "$@" ;;
    restart) cmd_restart "$@" ;;
    disable) cmd_disable "$@" ;;
    remove) cmd_remove "$@" ;;
    -h|--help|help) usage ;;
    *)
      audit "deny" "$cmd" "" "unknown-command"
      echo "ERROR: unknown command '$cmd'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
