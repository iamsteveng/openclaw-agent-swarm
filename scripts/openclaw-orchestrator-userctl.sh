#!/usr/bin/env bash
set -euo pipefail

# openclaw-orchestrator-userctl.sh
# Deterministic lifecycle wrapper for managed OpenClaw OS users.
# Option A + C hybrid onboarding:
# - automated provisioning (incl. systemd service creation)
# - guided pause/resume checkpoints for Slack token config + health verification

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
# FIX #2: Default service template now matches openclaw-gateway@<user>.service
SERVICE_TEMPLATE="${ORCH_SERVICE_TEMPLATE:-openclaw-gateway@%s.service}"
# FIX #5: CLI auth checkpoint replaced with health verification
HEALTH_CHECK_CMD_TEMPLATE="${ORCH_HEALTH_CHECK_CMD_TEMPLATE:-sudo -iu %s openclaw health}"
# FIX #3: System service source (openclaw node binary path)
OPENCLAW_BIN="${ORCH_OPENCLAW_BIN:-/home/ubuntu/.npm-global/lib/node_modules/openclaw/dist/index.js}"
OPENCLAW_SYMLINK="${ORCH_OPENCLAW_SYMLINK:-/usr/local/bin/openclaw}"
# Gateway port base — each user gets base + uid offset, or set ORCH_GATEWAY_PORT_BASE
GATEWAY_PORT_BASE="${ORCH_GATEWAY_PORT_BASE:-18800}"
DRY_RUN="${ORCH_DRY_RUN:-0}"

MUTATING_COMMANDS=" add add_user resume restart disable remove "

PHASE_PROVISIONED="provisioned"
PHASE_WAIT_SLACK="waiting_slack_config"
PHASE_WAIT_HEALTH="waiting_health_check"
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
  HEALTH_CHECK_CMD_TEMPLATE="${ORCH_HEALTH_CHECK_CMD_TEMPLATE:-$HEALTH_CHECK_CMD_TEMPLATE}"
  OPENCLAW_BIN="${ORCH_OPENCLAW_BIN:-$OPENCLAW_BIN}"
  OPENCLAW_SYMLINK="${ORCH_OPENCLAW_SYMLINK:-$OPENCLAW_SYMLINK}"
  GATEWAY_PORT_BASE="${ORCH_GATEWAY_PORT_BASE:-$GATEWAY_PORT_BASE}"
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

user_state_file() { echo "$USERS_DIR/$1.state"; }
onboarding_state_file() { echo "$ONBOARDING_DIR/$1.state"; }
is_managed_user() { [[ -f "$(user_state_file "$1")" ]]; }
service_name_for() { printf "$SERVICE_TEMPLATE" "$1"; }

set_user_state() {
  local u="$1" status="$2"
  cat > "$(user_state_file "$u")" <<EOF
username=$u
status=$status
updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

read_onboarding_state() {
  local f
  f="$(onboarding_state_file "$1")"
  [[ -f "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f"
}

write_onboarding_state() {
  local u="$1" phase="$2" status="$3" retries="$4" note="${5:-}"
  cat > "$(onboarding_state_file "$u")" <<EOF
username=$u
phase=$phase
status=$status
retries=$retries
note=$note
updatedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

transition_onboarding() {
  local u="$1" next_phase="$2" next_status="$3" retry_count="$4" reason="${5:-}"
  local cur_phase="none" cur_status="none"
  if read_onboarding_state "$u"; then
    cur_phase="${phase:-none}"
    cur_status="${status:-none}"
  fi
  write_onboarding_state "$u" "$next_phase" "$next_status" "$retry_count" "$reason"
  audit "ok" "phase_transition" "$u" "from=${cur_phase}/${cur_status} to=${next_phase}/${next_status} reason=${reason}"
}

# FIX #1: Ensure openclaw binary is accessible to all users system-wide
ensure_openclaw_path() {
  local symlink="$OPENCLAW_SYMLINK"
  # If symlink already works, nothing to do
  if [[ -L "$symlink" ]] && [[ -x "$symlink" ]]; then
    # Verify a non-root user can actually traverse the path
    local target
    target="$(readlink -f "$symlink" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then
      # Make sure all intermediate directories are world-executable
      local dir
      dir="$(dirname "$target")"
      while [[ "$dir" != "/" && "$dir" != "." ]]; do
        chmod o+x "$dir" 2>/dev/null || true
        dir="$(dirname "$dir")"
      done
      chmod o+rx "$target" 2>/dev/null || true
    fi
    return 0
  fi
  if [[ ! -f "$OPENCLAW_BIN" ]]; then
    echo "WARNING: openclaw binary not found at $OPENCLAW_BIN — skipping PATH fix" >&2
    return 0
  fi
  ln -sf "$OPENCLAW_BIN" "$symlink"
  chmod o+rx "$OPENCLAW_BIN" 2>/dev/null || true
  # Ensure parent dirs are traversable
  local dir
  dir="$(dirname "$OPENCLAW_BIN")"
  while [[ "$dir" != "/" && "$dir" != "." ]]; do
    chmod o+x "$dir" 2>/dev/null || true
    dir="$(dirname "$dir")"
  done
  echo "openclaw symlinked to $symlink"
}

# FIX #3: Create system-level gateway service for a user
create_system_service() {
  local u="$1"
  local svc_file="/etc/systemd/system/openclaw-gateway@${u}.service"
  local uid
  uid="$(id -u "$u" 2>/dev/null || echo "0")"
  # Assign a port: base + (uid mod 1000) to avoid collision
  local port=$(( GATEWAY_PORT_BASE + (uid % 1000) ))
  local node_bin
  node_bin="$(command -v node 2>/dev/null || echo "/usr/bin/node")"
  local openclaw_dist
  openclaw_dist="$(dirname "$OPENCLAW_BIN")/index.js"

  if [[ -f "$svc_file" ]]; then
    echo "Service file $svc_file already exists, skipping creation."
    return 0
  fi

  cat > "$svc_file" <<EOF
[Unit]
Description=OpenClaw Gateway for ${u}
After=network-online.target
Wants=network-online.target

[Service]
User=${u}
ExecStart=${node_bin} ${openclaw_dist} gateway --port ${port}
Restart=always
RestartSec=5
TimeoutStopSec=30
TimeoutStartSec=30
SuccessExitStatus=0 143
KillMode=control-group
Environment=HOME=/home/${u}
Environment=TMPDIR=/tmp
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=OPENCLAW_GATEWAY_PORT=${port}
Environment=OPENCLAW_SYSTEMD_UNIT=openclaw-gateway@${u}.service
Environment=OPENCLAW_SERVICE_MARKER=openclaw
Environment=OPENCLAW_SERVICE_KIND=gateway

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  echo "Created service $svc_file (port $port)"

  # Write port to user state so it's visible in status
  echo "gateway_port=$port" >> "$(user_state_file "$u")"
}

# Auto-create Slack app if config token is set
try_auto_create_slack_app() {
  local u="$1"
  local token="${ORCH_SLACK_CONFIG_TOKEN:-}"
  local repo_dir
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local create_script="$repo_dir/scripts/slack-app-create.sh"

  if [[ -z "$token" || ! -f "$create_script" ]]; then
    return 1  # fall back to manual instructions
  fi

  echo "Slack config token found — running automated app creation..."
  ORCH_POLICY_FILE="$POLICY_FILE" bash "$create_script" "$u"
  return 0
}

# FIX #4: Slack config checkpoint — token-based with manifest import
print_slack_checkpoint() {
  local u="$1"
  local display_name="${u#oc_}"  # strip oc_ prefix for display
  local app_name="OpenClaw - ${display_name}"

  cat <<EOF
CHECKPOINT: Slack app + token config required for $u

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 1 — Create Slack app via manifest import (fastest method)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Go to https://api.slack.com/apps
  2. Click "Create New App" → "From a manifest"
  3. Select your workspace
  4. Paste this manifest JSON:

$(cat <<MANIFEST
{
  "display_information": {
    "name": "${app_name}"
  },
  "features": {
    "bot_user": {
      "display_name": "${app_name}",
      "always_online": true
    },
    "app_home": {
      "messages_tab_enabled": true,
      "messages_tab_read_only_enabled": false
    }
  },
  "oauth_config": {
    "scopes": {
      "bot": [
        "chat:write",
        "im:history",
        "im:read",
        "im:write",
        "channels:read",
        "channels:history",
        "groups:history",
        "mpim:history",
        "mpim:read",
        "mpim:write",
        "users:read",
        "app_mentions:read",
        "reactions:read",
        "reactions:write",
        "files:read",
        "files:write"
      ]
    }
  },
  "settings": {
    "socket_mode_enabled": true,
    "event_subscriptions": {
      "bot_events": [
        "app_mention",
        "message.channels",
        "message.groups",
        "message.im",
        "message.mpim",
        "reaction_added",
        "reaction_removed"
      ]
    }
  }
}
MANIFEST
)

  5. Click "Create" → "Install to Workspace" → allow
  6. Copy the Bot Token (xoxb-...) from OAuth & Permissions

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 2 — Generate App Token (Socket Mode)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. In your new app → Settings → Basic Information
  2. Scroll to "App-Level Tokens" → "Generate Token and Scopes"
  3. Name it anything, add scope: connections:write
  4. Copy the App Token (xapp-...)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
STEP 3 — Configure tokens for $u
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  sudo -iu $u openclaw config set channels.slack.botToken "xoxb-..."
  sudo -iu $u openclaw config set channels.slack.appToken "xapp-..."

Then confirm:
  sudo openclaw-userctl resume $u DONE
If it fails:
  sudo openclaw-userctl resume $u RETRY "reason"
EOF
}

# FIX #5: Health check checkpoint instead of interactive configure
print_health_checkpoint() {
  local u="$1"
  local cmd
  printf -v cmd "$HEALTH_CHECK_CMD_TEMPLATE" "$u"
  cat <<EOF
CHECKPOINT: Gateway health verification required for $u

Verify the gateway and Slack channel are up:
  $cmd

Expected output includes: Slack: ok
Then confirm:
  sudo openclaw-userctl resume $u DONE
If it fails:
  sudo openclaw-userctl resume $u RETRY "reason"
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

  # FIX #1: Ensure openclaw is in PATH for all users before proceeding
  ensure_openclaw_path

  # Create OS user if needed
  if ! id "$u" >/dev/null 2>&1; then
    run_cmd useradd --create-home --shell /bin/bash "$u"
  fi

  # Enable systemd lingering so user services can persist
  run_cmd loginctl enable-linger "$u" 2>/dev/null || true

  mkdir -p "$WORKSPACES_DIR/$u"
  set_user_state "$u" "pending_auth"

  # Run openclaw setup for the new user
  run_cmd sudo -iu "$u" openclaw setup 2>/dev/null || true

  # Apply MVP workspace template if repo is available
  local repo_dir
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$repo_dir/scripts/apply-mvp-v1.sh" ]]; then
    run_cmd bash "$repo_dir/scripts/apply-mvp-v1.sh" "/home/$u/.openclaw/workspace" 2>/dev/null || true
    echo "MVP workspace template applied for $u."
    echo "ACTION REQUIRED: Customize /home/$u/.openclaw/workspace/USER.md with $u's name, role, and Slack user ID."
  fi

  # FIX #3: Create system-level service file
  create_system_service "$u"

  transition_onboarding "$u" "$PHASE_PROVISIONED" "in_progress" 0 "provisioning-complete"
  transition_onboarding "$u" "$PHASE_WAIT_SLACK" "waiting_operator_action" 0 "awaiting-slack-config"

  audit "ok" "add_user" "$u" "provisioned-awaiting-slack"
  echo "Provisioning complete for $u."

  # Try automated Slack app creation; fall back to manual instructions
  if ! try_auto_create_slack_app "$u"; then
    print_slack_checkpoint "$u"
  else
    echo ""
    echo "Slack app configured. Confirm with:"
    echo "  sudo openclaw-userctl resume $u DONE"
  fi
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
        transition_onboarding "$u" "$PHASE_WAIT_HEALTH" "waiting_operator_action" "$r" "slack-complete-awaiting-health"
        audit "ok" "resume" "$u" "advanced-to-health-check"
        # FIX #5: Health check checkpoint instead of configure
        print_health_checkpoint "$u"
        return
      fi
      if [[ "$p" == "$PHASE_WAIT_HEALTH" ]]; then
        transition_onboarding "$u" "$PHASE_FINALIZING" "in_progress" "$r" "health-ok-finalizing"

        local svc
        svc="$(service_name_for "$u")"

        # FIX #6: Idempotent finalize — check if already active before enabling/restarting
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
          echo "Service $svc already active — skipping enable/restart."
        else
          run_cmd systemctl enable "$svc"
          run_cmd systemctl restart "$svc"
        fi

        set_user_state "$u" "enabled"
        transition_onboarding "$u" "$PHASE_COMPLETE" "done" "$r" "onboarding-complete"
        audit "ok" "resume" "$u" "completed"
        echo "Onboarding complete for $u"
        return
      fi
      audit "deny" "resume" "$u" "invalid-done-phase=$p"
      echo "ERROR: DONE is only valid in phases: $PHASE_WAIT_SLACK, $PHASE_WAIT_HEALTH (current: $p)" >&2
      exit 10
      ;;
    RETRY)
      if [[ "$p" != "$PHASE_WAIT_SLACK" && "$p" != "$PHASE_WAIT_HEALTH" ]]; then
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
        print_health_checkpoint "$u"
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

  ensure_openclaw_path

  if ! id "$u" >/dev/null 2>&1; then
    run_cmd useradd --create-home --shell /bin/bash "$u"
  fi

  run_cmd loginctl enable-linger "$u" 2>/dev/null || true
  mkdir -p "$WORKSPACES_DIR/$u"
  run_cmd sudo -iu "$u" openclaw setup 2>/dev/null || true
  create_system_service "$u"
  set_user_state "$u" "enabled"

  local svc
  svc="$(service_name_for "$u")"
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    echo "Service $svc already active."
  else
    run_cmd systemctl enable "$svc"
    run_cmd systemctl restart "$svc"
  fi

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
    printf '%s\t%s\t%s\tonboarding=%s/%s\n' "$username" "${status:-?}" "${updatedAt:-?}" "$ob_phase" "$ob_status"
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
  echo "status: ${status:-?}"
  echo "updatedAt: ${updatedAt:-?}"
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

  # Stop service if running (idempotent)
  systemctl disable --now "$svc" 2>/dev/null || true
  # Remove system service file
  local svc_file="/etc/systemd/system/${svc}"
  if [[ -f "$svc_file" ]]; then
    rm -f "$svc_file"
    systemctl daemon-reload
  fi

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
    [[ -f "$ob_state_file" ]] && mv "$ob_state_file" "$archive_prefix.onboarding.state"
    [[ -d "$WORKSPACES_DIR/$u" ]] && mv "$WORKSPACES_DIR/$u" "$archive_prefix.workspace"
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
