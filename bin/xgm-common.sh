#!/bin/bash
# Shared helpers for the bin/ scripts. Source it, don't run it:
#   . "$(dirname "$(readlink -f "$0")")/xgm-common.sh"
# Only defines functions; sourcing it has no side effects.
ROOT="${XGM_ROOT:-}"

# The display-manager unit: sddm on SteamOS/Bazzite, plasmalogin on CachyOS Handheld.
# Resolved from the display-manager.service alias, but only known units are accepted, and only if
# the alias target exists. Anything else falls back to sddm.service (the pre-alias behavior) with
# a warning on stderr. Other display managers (gdm, lightdm, greetd) stay on the fallback until a
# community tester has verified enable/eject with them; then add them to the case below.
xgm_dm_service() {
  local alias="$ROOT/etc/systemd/system/display-manager.service" target unit
  if [ ! -L "$alias" ] && [ ! -e "$alias" ]; then
    echo "sddm.service"
    return 0
  fi
  target=$(readlink -f "$alias" 2>/dev/null)
  unit=$(basename "$target" 2>/dev/null)
  case "$unit" in
    sddm.service|plasmalogin.service)
      if [ -e "$target" ]; then
        echo "$unit"
        return 0
      fi
      ;;
  esac
  echo "WARNING: unrecognized display manager '$unit', using sddm.service" >&2
  echo "sddm.service"
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
