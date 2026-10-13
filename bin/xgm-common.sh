#!/bin/bash
# Shared helpers for the bin/ scripts. Source it, don't run it, and fail fast (exit 9, catalogued
# in main.py) before touching anything if it's missing:
#   . "$(dirname "$(readlink -f "$0")")/xgm-common.sh" || { echo "ERROR: ..."; exit 9; }
# Only defines functions and constants; sourcing it has no side effects.
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

# The user whose session the plugin configures: the owner of the Steam process; when Steam isn't
# running (e.g. at boot), the first regular user (uid 1000-65533) with a home dir; else "deck".
xgm_primary_user() {
  local user candidate
  user=$(ps -o user= -C steam | head -n 1 | xargs)
  if [ -z "$user" ]; then
    for candidate in $(awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' "$ROOT/etc/passwd" 2>/dev/null); do
      if [ -d "$ROOT/home/$candidate" ]; then
        user="$candidate"
        break
      fi
    done
  fi
  echo "${user:-deck}"
}

# The host OS, with the same rules as main.py get_os_type: steamos | cachyos | bazzite |
# bazzite-nvidia | unsupported. For callers that don't get the OS as an argument (egpu-sync at boot).
xgm_os_type() {
  local data
  data=$(tr '[:upper:]' '[:lower:]' < "$ROOT/etc/os-release" 2>/dev/null) || { echo "unsupported"; return 0; }
  case "$data" in
    *bazzite*)
      if [[ "$data" == *nvidia* ]]; then echo "bazzite-nvidia"; else echo "bazzite"; fi ;;
    *cachyos*) echo "cachyos" ;;
    *steamos*) echo "steamos" ;;
    *) echo "unsupported" ;;
  esac
}

# Every variable egpu-enable injects on SteamOS/CachyOS (/etc/environment and systemctl
# set-environment). Keep in sync with egpu-enable.
XGM_ENV_VARS=(MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT)

# Undoes everything egpu-enable injects on SteamOS/CachyOS: the variables in /etc/environment,
# the system and user systemd managers, the Plasma env files and nvidia-egpu.conf. The user
# manager is skipped when the user has no runtime dir (no session yet, e.g. at early boot).
xgm_sanitize_environment() {
  local user="$1" var uid
  echo "Sanitizing the eGPU environment..."
  for var in "${XGM_ENV_VARS[@]}"; do
    sed -i "/^$var=/d" "$ROOT/etc/environment"
  done
  for var in "${XGM_ENV_VARS[@]}"; do
    systemctl unset-environment "$var"
  done
  uid=$(id -u "$user" 2>/dev/null)
  if [ -n "$uid" ] && [ -d "$ROOT/run/user/$uid" ]; then
    for var in "${XGM_ENV_VARS[@]}"; do
      sudo -u "$user" XDG_RUNTIME_DIR=/run/user/$uid systemctl --user unset-environment "$var"
    done
  fi
  rm -f "$ROOT/home/$user/.config/plasma-workspace/env/xgmobile-kwin.sh"
  rm -f "$ROOT/home/$user/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  rm -f "$ROOT/etc/modprobe.d/nvidia-egpu.conf"
}

# xgm_egpu_pci_paths <data_dir> [strict]: the eGPU's PCI device dir(s) in sysfs, one per line,
# resolved in this order:
#   1. the PCI address egpu-enable recorded in <data_dir>/egpu_pci_address, if that device exists
#      and is a display controller (PCI class 0x03....)
#   2. the display controller(s) that aren't the boot VGA device (boot_vga != 1); read from the PCI
#      bus, not the DRM cards, so it works before a driver is bound (early boot)
#   3. nothing
# With "strict" (the boot safety net), a well-formed record is final: if its device is gone or
# isn't a display controller, the eGPU is absent and step 2 is skipped. On a Flow laptop step 2
# would find the internal dGPU instead.
# DRM card numbers change between boots; the PCI address of the XG Mobile slot doesn't.
xgm_egpu_pci_paths() {
  local addr dev
  addr=$(cat "$1/egpu_pci_address" 2>/dev/null)
  if [[ "$addr" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
    if [[ "$(cat "$ROOT/sys/bus/pci/devices/$addr/class" 2>/dev/null)" == 0x03* ]]; then
      readlink -f "$ROOT/sys/bus/pci/devices/$addr"
      return 0
    fi
    [ "${2:-}" = "strict" ] && return 0
  fi
  for dev in $ROOT/sys/bus/pci/devices/*; do
    [[ "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] || continue
    [ "$(cat "$dev/boot_vga" 2>/dev/null)" = "1" ] && continue
    readlink -f "$dev"
  done
}

# xgm_drm_nodes <pci dir> [card|renderD]: the DRM node names (card0, renderD129...) that belong to
# that PCI device, matched through each sys/class/drm entry's device link. Never assumes numbers.
xgm_drm_nodes() {
  local entry name
  for entry in $ROOT/sys/class/drm/${2:-}*; do
    name=$(basename "$entry")
    [[ "$name" =~ ^(card|renderD)[0-9]+$ ]] || continue
    [ "$(readlink -f "$entry/device" 2>/dev/null)" = "$1" ] && echo "$name"
  done
}

# xgm_fb_nodes <pci dir>: the framebuffer devices (fb0, fb1...) that belong to that PCI device,
# matched through each sys/class/graphics entry's device link.
xgm_fb_nodes() {
  local entry name target
  for entry in $ROOT/sys/class/graphics/fb*; do
    name=$(basename "$entry")
    [[ "$name" =~ ^fb[0-9]+$ ]] || continue
    target=$(readlink -f "$entry/device" 2>/dev/null)
    if [ -n "$target" ] && { [ "$target" = "$1" ] || [[ "$target" == "$1"/* ]]; }; then
      echo "$name"
    fi
  done
}
