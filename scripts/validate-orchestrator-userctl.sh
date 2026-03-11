#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTL="$REPO_ROOT/scripts/openclaw-orchestrator-userctl.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export ORCH_STATE_ROOT="$TMP_DIR/state"
export ORCH_LOG_DIR="$TMP_DIR/log"
export ORCH_POLICY_FILE="$TMP_DIR/policy.env"
export ORCH_ALLOW_NON_ROOT=1
export ORCH_DRY_RUN=1
export ORCH_ALLOW_REGEX='^oc_[a-z0-9_]{2,24}$'
export ORCH_FORBIDDEN_USERS='root ec2-user nobody daemon'

cat > "$ORCH_POLICY_FILE" <<EOF
ORCH_ALLOW_REGEX='^oc_[a-z0-9_]{2,24}$'
ORCH_FORBIDDEN_USERS='root ec2-user nobody daemon'
ORCH_SERVICE_TEMPLATE='openclaw-agent@%s.service'
EOF

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

expect_fail() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$name expected failure"
  fi
  pass "$name"
}

expect_ok() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    fail "$name expected success"
  fi
  pass "$name"
}

expect_fail "invalid username rejected" "$CTL" add not_allowed
expect_fail "forbidden username rejected" "$CTL" add root
expect_fail "unknown command rejected" "$CTL" shell 'rm -rf /'

expect_ok "add managed user" "$CTL" add oc_alpha
expect_ok "list managed users" "$CTL" list
expect_ok "status managed user" "$CTL" status oc_alpha
expect_ok "disable managed user" "$CTL" disable oc_alpha
expect_ok "restart managed user" "$CTL" restart oc_alpha
expect_ok "remove managed user safe default" "$CTL" remove oc_alpha

expect_ok "add second user" "$CTL" add oc_beta
expect_ok "restart all" "$CTL" restart --all
expect_ok "remove with force" "$CTL" remove oc_beta --force

[[ -f "$ORCH_LOG_DIR/audit.log" ]] || fail "audit log not created"
grep -q 'cmd=add' "$ORCH_LOG_DIR/audit.log" || fail "audit log missing add entries"
pass "audit log populated"

echo "All orchestrator userctl validations passed."
