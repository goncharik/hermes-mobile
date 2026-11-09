#!/usr/bin/env bash
#
# Run the HermesKit test suite with live (unbuffered) output.
# `swift test` buffers stdout when piped; a pseudo-TTY via `script` streams it.
#
# Usage:
#   scripts/test.sh [extra swift test args]   e.g. --filter ChatFeatureTests
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v swift >/dev/null 2>&1; then
  echo "swift: command not found" >&2
  exit 127
fi
if script -q -c true /dev/null >/dev/null 2>&1; then
  # util-linux (Linux): command must be passed through -c.
  exec script -q -c "swift test --package-path HermesKit $(printf '%q ' "$@")" /dev/null
else
  # BSD/macOS: command arguments are accepted directly.
  exec script -q /dev/null swift test --package-path HermesKit "$@"
fi
