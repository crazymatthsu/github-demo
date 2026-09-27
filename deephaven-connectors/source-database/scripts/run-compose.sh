#!/usr/bin/env bash
# Thin wrapper (D6 §6.8): the one implementation is <repo>/scripts/run-compose.sh; this copy only pins the
# app directory. Usage: scripts/run-compose.sh <env> <flow> <AppName> <AppInstance> <command> [options]
set -euo pipefail
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_ROOT="$(git -C "$APP_DIR" rev-parse --show-toplevel 2>/dev/null || (cd "$APP_DIR/../.." && pwd -P))"
exec "$REPO_ROOT/scripts/run-compose.sh" --app-dir "$APP_DIR" "$@"
