#!/usr/bin/env bash
set -euo pipefail

npm_bin="${NPM_BIN:-npm}"
if command -v npm.cmd >/dev/null 2>&1; then
  npm_bin="npm.cmd"
fi

"${npm_bin}" test
