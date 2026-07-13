#!/usr/bin/env bash
set -euo pipefail

run_npm() {
  if command -v cmd.exe >/dev/null 2>&1 && cmd.exe /C exit >/dev/null 2>&1; then
    cmd.exe /C npm.cmd "$@"
  elif command -v npm >/dev/null 2>&1 && npm --version >/dev/null 2>&1; then
    npm "$@"
  else
    echo "npm is not available in this shell" >&2
    exit 127
  fi
}

run_npx() {
  if command -v cmd.exe >/dev/null 2>&1 && cmd.exe /C exit >/dev/null 2>&1; then
    cmd.exe /C npx.cmd "$@"
  elif command -v npx >/dev/null 2>&1 && npx --version >/dev/null 2>&1; then
    npx "$@"
  else
    echo "npx is not available in this shell" >&2
    exit 127
  fi
}

run_npm install
run_npm run compile
run_npm test
bash scripts/check-loc.sh
run_npx prettier --check --ignore-unknown "hardhat.config.js" "package.json" ".github/**/*.yml" ".vscode/*.json" "scripts/*.sh" "test/*.js" "src/**/*.sol" "README.md" "SECURITY.md"
