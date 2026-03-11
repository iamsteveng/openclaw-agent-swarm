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
ORCH_SLACK_OAUTH_CMD_TEMPLATE='sudo -iu %s openclaw auth slack'
ORCH_CLI_AUTH_CMD_TEMPLATE='sudo -iu %s openclaw auth login'
EOF

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

expect_fail() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name expected failure"; fi
  pass "$name"
}
expect_ok() {
  local name="$1"; shift
  if ! "$@" >/dev/null 2>&1; then fail "$name expected success"; fi
  pass "$name"
}

expect_fail "invalid username rejected" "$CTL" add_user not_allowed
expect_fail "forbidden username rejected" "$CTL" add_user root
expect_fail "unknown command rejected" "$CTL" shell 'rm -rf /'

expect_ok "add_user starts staged onboarding" "$CTL" add_user oc_alpha
grep -q 'phase=waiting_slack_oauth' "$ORCH_STATE_ROOT/onboarding/oc_alpha.state" || fail "expected waiting_slack_oauth phase"
pass "pause checkpoint persisted"

expect_ok "resume RETRY at slack checkpoint" "$CTL" resume oc_alpha RETRY "oauth popup closed"
grep -q 'retries=1' "$ORCH_STATE_ROOT/onboarding/oc_alpha.state" || fail "expected retries=1"
pass "retry counter increments"

expect_ok "resume DONE moves to cli checkpoint" "$CTL" resume oc_alpha DONE
grep -q 'phase=waiting_cli_auth' "$ORCH_STATE_ROOT/onboarding/oc_alpha.state" || fail "expected waiting_cli_auth phase"
pass "transition to cli checkpoint"

expect_ok "resume DONE completes onboarding" "$CTL" resume oc_alpha DONE
grep -q 'phase=complete' "$ORCH_STATE_ROOT/onboarding/oc_alpha.state" || fail "expected complete phase"
grep -q 'status=enabled' "$ORCH_STATE_ROOT/users/oc_alpha.state" || fail "expected user status enabled"
pass "onboarding completion transition"

expect_ok "status managed user" "$CTL" status oc_alpha
expect_ok "list managed users" "$CTL" list
expect_ok "disable managed user" "$CTL" disable oc_alpha
expect_ok "restart managed user" "$CTL" restart oc_alpha
expect_ok "remove managed user safe default" "$CTL" remove oc_alpha
ls "$ORCH_STATE_ROOT/archive"/oc_alpha-*.state >/dev/null 2>&1 || fail "safe remove should archive state"
ls "$ORCH_STATE_ROOT/archive"/oc_alpha-*.onboarding.state >/dev/null 2>&1 || fail "safe remove should archive onboarding state"
pass "safe remove archives state and onboarding"

expect_ok "add legacy mode user" "$CTL" add oc_beta
expect_ok "restart all" "$CTL" restart --all
expect_ok "remove with force-delete" "$CTL" remove oc_beta --force-delete
[[ ! -f "$ORCH_STATE_ROOT/users/oc_beta.state" ]] || fail "force-delete should remove active state file"
pass "force-delete removed state"

expect_ok "mark failed flow" "$CTL" add_user oc_gamma
expect_ok "resume FAIL supported" "$CTL" resume oc_gamma FAIL "cli token expired"
grep -q 'phase=failed' "$ORCH_STATE_ROOT/onboarding/oc_gamma.state" || fail "expected failed phase"
pass "failure transition recorded"

[[ -f "$ORCH_LOG_DIR/audit.log" ]] || fail "audit log not created"
grep -q 'cmd=phase_transition' "$ORCH_LOG_DIR/audit.log" || fail "audit log missing phase transitions"
grep -q 'cmd=resume' "$ORCH_LOG_DIR/audit.log" || fail "audit log missing resume entries"
grep -q 'cmd=remove' "$ORCH_LOG_DIR/audit.log" || fail "audit log missing remove entries"
pass "audit log populated"

echo "All orchestrator userctl validations passed."
