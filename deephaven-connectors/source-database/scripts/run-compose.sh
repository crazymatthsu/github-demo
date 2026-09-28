#!/usr/bin/env bash
# Thin wrapper (D6 §6.8): the one implementation is <root>/scripts/run-compose.sh; this copy only pins the
# app directory. Usage: scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> <command> [options]
# <root>: the nearest ancestor holding a .platform-bundle marker (a host bundle on a box of a pool, DL-39),
# else the git checkout, else two levels above the app directory.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPO_ROOT=""
dir="$SCRIPT_DIR"
while :; do
    if [ -f "$dir/.platform-bundle" ]; then REPO_ROOT="$dir"; break; fi
    [ "$dir" != / ] || break
    dir="$(dirname "$dir")"
done
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(git -C "$APP_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$APP_DIR/../.." && pwd -P))"
exec "$REPO_ROOT/scripts/run-compose.sh" --app-dir "$APP_DIR" "$@"
