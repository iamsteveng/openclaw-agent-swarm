#!/usr/bin/env bash
set -euo pipefail

# openclaw-orchestrator-userctl.sh
# Deterministic lifecycle wrapper for managed OpenClaw OS users.

STATE_ROOT="${ORCH_STATE_ROOT:-/var/lib/openclaw-orchestrator}"
USERS_DIR="$STATE_ROOT/users"
ARCHIVE_DIR="$STATE_ROOT/archive"
WORKSPACES_DIR="$STATE_ROOT/workspaces"
LOG_DIR="${ORCH_LOG_DIR:-/var/log/openclaw-orchestrator}"
AUDIT_LOG="$LOG_DIR/audit.log"
POLICY_FILE="${ORCH_POLICY_FILE:-/etc/openclaw-orchestrator/policy.env}"
ALLOW_REGEX="${ORCH_ALLOW_REGEX:-^oc_[a-z0-9_]{2,24}$}"
FORBIDDEN_USERS_DEFAULT="root ec2-user nobody daemon bin sys"
SERVICE_TEMPLATE="${ORCH_SERVICE_TEMPLATE:-openclaw-agent@%s.service}"
DRY_RUN="${ORCH_DRY_RUN:-0}"

MUTATING_COMMANDS=" add restart disable remove "

load_policy() {
  if [[ -f "$POLICY_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$POLICY_FILE"
  fi
  ALLOW_REGEX="${ORCH_ALLOW_REGEX:-$ALLOW_REGEX}"
  FORBIDDEN_USERS="${ORCH_FORBIDDEN_USERS:-$FORBIDDEN_USERS_DEFAULT}"
}

usage() {
  cat <<'EOF'
Usage:
  openclaw-orchestrator-userctl.sh add <username>
  openclaw-orchestrator-userctl.sh list
  openclaw-orchestrator-userctl.sh status [username]
  openclaw-orchestrator-userctl.sh restart <username|--all>
  openclaw-orchestrator-userctl.sh disable <username>
  openclaw-orchestrator-userctl.sh remove <username> [--force-delete] [--purge-home]

Notes:
  - Fixed subcommands only; arbitrary shell passthrough is not supported.
  - Mutating commands require root unless ORCH_ALLOW_NON_ROOT=1.
  - Use ORCH_DRY_RUN=1 for no-op command execution in test environments.
EOF
}

ensure_dirs() {
  mkdir -p "$USERS_DIR" "$ARCHIVE_DIR" "$WORKSPACES_DIR" "$LOG_DIR"
  touch "$AUDIT_LOG"
  chmod 700 "$STATE_ROOT" "$USERS_DIR" || true
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
    printf '%s\t%s\t%s\n' "$username" "$status" "$updatedAt"
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

  local svc state_file ts archive_prefix
  svc="$(service_name_for "$u")"
  state_file="$(user_state_file "$u")"
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_prefix="$ARCHIVE_DIR/$u-$ts"

  run_cmd systemctl disable --now "$svc"

  if [[ "$force" -eq 1 ]]; then
    rm -f "$state_file"
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
