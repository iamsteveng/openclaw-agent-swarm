#!/usr/bin/env bash
# slack-app-create.sh
# Automates Slack app creation for a new OpenClaw user.
# - Creates the Slack app via manifest API (fully automated)
# - Guides through 2 manual steps (install + app token)
# - Configures bot + app tokens into the user's OpenClaw
#
# Usage:
#   sudo ./slack-app-create.sh <username> [--policy <policy_file>]
#   e.g: sudo ./slack-app-create.sh oc_alice

set -euo pipefail

POLICY_FILE="${ORCH_POLICY_FILE:-/etc/openclaw-orchestrator/policy.env}"
SLACK_API="https://slack.com"

# ── helpers ────────────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 <oc_username> [--policy <policy_file>]"
  echo "  oc_username  must match ^oc_[a-z0-9_]{2,24}\$"
  exit 1
}

die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

slack_api() {
  local endpoint="$1" token="$2" payload="$3"
  curl -s -X POST "${SLACK_API}/api/${endpoint}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$payload"
}

check_ok() {
  local resp="$1" context="$2"
  local ok
  ok="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ok','false'))")"
  if [[ "$ok" != "True" && "$ok" != "true" ]]; then
    local err
    err="$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error','unknown'))")"
    die "$context failed: $err"
  fi
}

# ── arg parsing ────────────────────────────────────────────────────────────────

USERNAME="${1:-}"
[[ -n "$USERNAME" ]] || usage
[[ "$USERNAME" =~ ^oc_[a-z0-9_]{2,24}$ ]] || die "Invalid username '$USERNAME'. Must match ^oc_[a-z0-9_]{2,24}\$"
[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)"

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --policy) POLICY_FILE="$2"; shift 2 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_cmd curl
require_cmd python3

# ── load policy ────────────────────────────────────────────────────────────────

[[ -f "$POLICY_FILE" ]] && source "$POLICY_FILE"

SLACK_CONFIG_TOKEN="${ORCH_SLACK_CONFIG_TOKEN:-}"
[[ -n "$SLACK_CONFIG_TOKEN" ]] || die "ORCH_SLACK_CONFIG_TOKEN not set in $POLICY_FILE"

DISPLAY_NAME="${USERNAME#oc_}"
APP_NAME="OpenClaw Agent - ${DISPLAY_NAME}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Slack App Creator for: $USERNAME"
echo "  App name: $APP_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── step 1: rotate config token ────────────────────────────────────────────────

echo "[1/4] Rotating config token..."
ROTATE_RESP=$(curl -s -X POST "${SLACK_API}/api/tooling.tokens.rotate" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "refresh_token=${SLACK_CONFIG_TOKEN}")

check_ok "$ROTATE_RESP" "Token rotation"

ACCESS_TOKEN="$(echo "$ROTATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")"
NEW_REFRESH_TOKEN="$(echo "$ROTATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['refresh_token'])")"
TEAM_ID="$(echo "$ROTATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['team_id'])")"

# Persist the new refresh token back to policy
sudo sed -i "s|ORCH_SLACK_CONFIG_TOKEN=.*|ORCH_SLACK_CONFIG_TOKEN='${NEW_REFRESH_TOKEN}'|" "$POLICY_FILE"
echo "    Token rotated and saved."

# ── step 2: create slack app via manifest ──────────────────────────────────────

echo "[2/4] Creating Slack app via manifest..."

MANIFEST=$(python3 -c "
import json
manifest = {
  'display_information': {'name': '${APP_NAME}'},
  'features': {
    'bot_user': {'display_name': '${APP_NAME}', 'always_online': True},
    'app_home': {'messages_tab_enabled': True, 'messages_tab_read_only_enabled': False}
  },
  'oauth_config': {
    'scopes': {
      'bot': [
        'chat:write','im:history','im:read','im:write',
        'channels:history','channels:read','groups:history',
        'mpim:history','mpim:read','mpim:write',
        'users:read','app_mentions:read',
        'reactions:read','reactions:write',
        'files:read','files:write'
      ]
    }
  },
  'settings': {
    'socket_mode_enabled': True,
    'event_subscriptions': {
      'bot_events': [
        'app_mention','message.im','message.channels',
        'message.groups','message.mpim',
        'reaction_added','reaction_removed'
      ]
    }
  }
}
print(json.dumps({'manifest': manifest}))
")

CREATE_RESP=$(slack_api "apps.manifest.create" "$ACCESS_TOKEN" "$MANIFEST")
check_ok "$CREATE_RESP" "App creation"

APP_ID="$(echo "$CREATE_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['app_id'])")"
MANAGE_URL="${SLACK_API}/apps/${APP_ID}/general"
INSTALL_URL="${SLACK_API}/apps/${APP_ID}/oauth"

echo "    App created: $APP_ID ($APP_NAME)"

# ── step 3: print manual steps ─────────────────────────────────────────────────

echo ""
echo "[3/4] Manual steps required (2 steps):"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP A — Install app to workspace (get Bot Token)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Go to: $INSTALL_URL"
echo "Click 'Install to Workspace' → Allow"
echo "Copy the Bot User OAuth Token (xoxb-...) shown on the same page"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP B — Generate App Token (Socket Mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Go to: $MANAGE_URL"
echo "Scroll to 'App-Level Tokens' → Generate Token"
echo "Name: socket-mode  |  Scope: connections:write"
echo "Copy the App Token (xapp-...)"
echo ""

# ── step 4: collect tokens and configure openclaw ──────────────────────────────

echo "[4/4] Enter tokens to configure OpenClaw for $USERNAME"
echo ""
read -rp "Bot Token (xoxb-...): " BOT_TOKEN
read -rp "App Token (xapp-...): " APP_TOKEN

[[ "$BOT_TOKEN" == xoxb-* ]] || die "Invalid bot token (must start with xoxb-)"
[[ "$APP_TOKEN" == xapp-* ]] || die "Invalid app token (must start with xapp-)"

echo ""
echo "Configuring OpenClaw for $USERNAME..."
sudo -iu "$USERNAME" openclaw config set channels.slack.botToken "$BOT_TOKEN"
sudo -iu "$USERNAME" openclaw config set channels.slack.appToken "$APP_TOKEN"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Slack app created and configured"
echo "  App:      $APP_NAME ($APP_ID)"
echo "  User:     $USERNAME"
echo "  Manage:   $MANAGE_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next: restart the gateway and verify"
echo "  sudo systemctl restart openclaw-gateway@${USERNAME}.service"
echo "  sudo -iu $USERNAME openclaw health"
