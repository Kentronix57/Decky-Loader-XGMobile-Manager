#!/bin/bash
# Shared helpers for the bin/ scripts. Source it, don't run it:
#   . "$(dirname "$(readlink -f "$0")")/xgm-common.sh"
# Only defines functions; sourcing it has no side effects.
ROOT="${XGM_ROOT:-}"

# The display-manager unit: sddm on SteamOS/Bazzite, plasmalogin on CachyOS Handheld.
# Resolved from the display-manager.service alias; falls back to sddm.service.
xgm_dm_service() {
  local target unit
  target=$(readlink -f "$ROOT/etc/systemd/system/display-manager.service" 2>/dev/null)
  unit=$(basename "$target" 2>/dev/null)
  if [[ "$unit" == ?*.service ]] && [ "$unit" != "display-manager.service" ]; then
    echo "$unit"
  else
    echo "sddm.service"
  fi
}

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
