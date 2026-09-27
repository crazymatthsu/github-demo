#!/usr/bin/env bash
# Thin wrapper (D6 §6.8): the one implementation is <repo>/scripts/smoke.sh; this copy only pins the app
# directory. Usage: scripts/smoke.sh [<base-url>]
#                   scripts/smoke.sh <env> <flow> <AppName> <AppInstance> [<base-url>]   (as run-compose.sh health calls it)
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(git -C "$APP_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$APP_DIR/../.." && pwd -P))"
exec "$REPO_ROOT/scripts/smoke.sh" --app-dir "$APP_DIR" "$@"
