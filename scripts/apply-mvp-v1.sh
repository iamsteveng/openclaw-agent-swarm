#!/usr/bin/env bash
set -euo pipefail

# Deterministic installer for OpenClaw Agent Swarm MVP v1
# Usage:
#   ./scripts/apply-mvp-v1.sh /path/to/openclaw/workspace
# If no path is provided, defaults to current directory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_WORKSPACE="${1:-$(pwd)}"

REQUIRED_FILES=(
  "AGENTS.md"
  "SOUL.md"
  "USER.md"
  "TOOLS.md"
  "MEMORY.md"
  "HEARTBEAT.md"
  "MVP-V1.md"
)

mkdir -p "$TARGET_WORKSPACE"

backup_dir="$TARGET_WORKSPACE/.mvp-v1-backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup_dir"

copy_with_backup() {
  local src="$1"
  local dst="$2"

  if [[ -f "$dst" ]]; then
    cp "$dst" "$backup_dir/$(basename "$dst")"
  fi
  cp "$src" "$dst"
}

for f in "${REQUIRED_FILES[@]}"; do
  copy_with_backup "$REPO_ROOT/$f" "$TARGET_WORKSPACE/$f"
done

mkdir -p "$TARGET_WORKSPACE/memory"

today_file="$TARGET_WORKSPACE/memory/$(date -u +%F).md"
if [[ ! -f "$today_file" ]]; then
  cat > "$today_file" <<'EOF'
# Daily Memory Log

- Created by apply-mvp-v1.sh
- Add session notes, decisions, and follow-ups here.
EOF
fi

repo_commit="unknown"
if command -v git >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    repo_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  fi
fi

cat > "$TARGET_WORKSPACE/.mvp-v1-manifest.json" <<EOF
{
  "template": "openclaw-agent-swarm",
  "version": "mvp-v1",
  "appliedAtUtc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sourceRepo": "$(basename "$REPO_ROOT")",
  "sourceCommit": "$repo_commit",
  "files": [
    "AGENTS.md",
    "SOUL.md",
    "USER.md",
    "TOOLS.md",
    "MEMORY.md",
    "HEARTBEAT.md",
    "MVP-V1.md"
  ]
}
EOF

echo "Applied OpenClaw Agent Swarm MVP v1 to: $TARGET_WORKSPACE"
echo "Backup (if any overwritten files): $backup_dir"
echo "Manifest: $TARGET_WORKSPACE/.mvp-v1-manifest.json"
