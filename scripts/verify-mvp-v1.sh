#!/usr/bin/env bash
set -euo pipefail

# Verify target workspace matches template checksums for core MVP v1 files
# Usage:
#   ./scripts/verify-mvp-v1.sh /path/to/openclaw/workspace

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_WORKSPACE="${1:-$(pwd)}"

FILES=(
  "AGENTS.md"
  "SOUL.md"
  "USER.md"
  "TOOLS.md"
  "MEMORY.md"
  "HEARTBEAT.md"
  "MVP-V1.md"
)

if ! command -v sha256sum >/dev/null 2>&1; then
  echo "sha256sum not found; cannot verify." >&2
  exit 2
fi

status=0

for f in "${FILES[@]}"; do
  src="$REPO_ROOT/$f"
  dst="$TARGET_WORKSPACE/$f"

  if [[ ! -f "$dst" ]]; then
    echo "MISSING: $f"
    status=1
    continue
  fi

  src_hash="$(sha256sum "$src" | awk '{print $1}')"
  dst_hash="$(sha256sum "$dst" | awk '{print $1}')"

  if [[ "$src_hash" != "$dst_hash" ]]; then
    echo "DRIFT: $f"
    status=1
  else
    echo "OK: $f"
  fi
done

if [[ -f "$TARGET_WORKSPACE/.mvp-v1-manifest.json" ]]; then
  echo "OK: .mvp-v1-manifest.json present"
else
  echo "WARN: .mvp-v1-manifest.json missing"
fi

if [[ $status -eq 0 ]]; then
  echo "VERIFIED: Workspace matches MVP v1 template core files."
else
  echo "FAILED: Workspace does not match MVP v1 template."
fi

exit $status
