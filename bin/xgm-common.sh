#!/bin/bash
# Shared helpers for the bin/ scripts. Source it, don't run it:
#   . "$(dirname "$(readlink -f "$0")")/xgm-common.sh"
# Only defines functions; sourcing it has no side effects.
ROOT="${XGM_ROOT:-}"

# steamos-readonly only exists on SteamOS; elsewhere these do nothing.
xgm_ro_disable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable
  fi
}

xgm_ro_enable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly enable
  fi
}
