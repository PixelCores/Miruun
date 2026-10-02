#!/bin/bash
# Build local source only. Never downloads, installs, opens a browser or changes
# Codex data. The output app is not Developer-ID signed or notarized.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$SCRIPT_DIR/scripts/build-app.sh" "$@"
