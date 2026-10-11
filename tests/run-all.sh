#!/usr/bin/env bash
# Tier 0: every check that needs no hardware, in one command. Run as a normal user:
#   bash tests/run-all.sh
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: don't run the test suite as root or with sudo." >&2
  echo "The bin/ tests rely on a missed \$ROOT prefix failing with 'permission denied'." >&2
  exit 1
fi

cd "$(dirname "$0")/.."

step() { printf '\n==> %s\n' "$*"; }

step "python3 -m py_compile main.py"
python3 -m py_compile main.py

step "bash -n bin/*"
for f in bin/*; do
  bash -n "$f"
done

step "shellcheck --severity=error"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error bin/* tests/run-all.sh tests/bin/helpers/*.bash tests/bin/shims/* tests/bin/shims-optional/*
elif [ -n "${CI:-}" ]; then
  echo "ERROR: shellcheck is required in CI." >&2
  exit 1
else
  echo "WARNING: shellcheck not installed, skipping (CI runs it)." >&2
fi

# Gate: prove every absolute path in bin/ is $ROOT-prefixed before any bin/ script is executed.
step "path audit (gate)"
pnpm test:audit

if ! python3 -c "import pytest" >/dev/null 2>&1; then
  step "pytest not importable, using .venv"
  [ -x .venv/bin/python3 ] || python3 -m venv .venv
  .venv/bin/python3 -c "import pytest" >/dev/null 2>&1 || .venv/bin/python3 -m pip install -q -r requirements-dev.txt
  export PATH="$PWD/.venv/bin:$PATH"
fi

step "pnpm build"
pnpm build

step "pnpm test"
pnpm test

printf '\nTier 0 passed.\n'
