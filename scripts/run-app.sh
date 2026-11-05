#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$("$SCRIPT_DIR/build-app.sh" "$@" | tail -n 1)"

open "$APP_BUNDLE"
