# shellcheck shell=bash
# Per-test sandbox for running bin/ scripts against a fake system tree.
#
# Every absolute path in an in-scope bin/ script is prefixed with $ROOT (from XGM_ROOT), so the
# scripts read and write under $BATS_TEST_TMPDIR/root instead of /. System commands are replaced
# by the shims in tests/bin/shims, and PATH holds only those shims plus symlinks to a fixed list
# of harmless coreutils, so anything unexpected fails with "command not found" instead of running
# the real thing.

XGM_REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
XGM_SHIMS="$XGM_REPO/tests/bin/shims"
XGM_OPTIONAL_SHIMS="$XGM_REPO/tests/bin/shims-optional"

load "$XGM_REPO/node_modules/bats-support/load"
load "$XGM_REPO/node_modules/bats-assert/load"
# shellcheck source=../../audit/audit.bash
source "$XGM_REPO/tests/audit/audit.bash"

# Real tools the scripts (and the shims) are allowed to use.
SANDBOX_TOOLS=(bash env cat grep sed awk ls mkdir mv rm ln chmod cp head tail wc xargs cut tr echo date readlink dirname basename touch sort true false printf)

refuse_root() {
  if [ "$EUID" -eq 0 ]; then
    echo "Refusing to run the bin/ tests as root: a missed \$ROOT prefix could modify the host." >&2
    exit 1
  fi
}

refuse_root

# Gate: the path audit must pass before any bin/ script runs. It runs once per bats invocation
# (whichever file comes first) and the result is cached in $BATS_RUN_TMPDIR, so running a single
# file, `bats -f`, or an editor test runner is gated the same way as the full suite.
require_path_audit() {
  local marker="$BATS_RUN_TMPDIR/xgm-path-audit" out result=pass
  if [ ! -s "$marker" ]; then
    out="$(audit_all 2>&1)" || result=fail
    printf '%s\n%s\n' "$result" "$out" > "$marker.$$"
    mv -f "$marker.$$" "$marker"
  fi
  if [ "$(head -n 1 "$marker")" != "pass" ]; then
    echo "Path audit failed, so no bin/ script was run (tests/audit/path-audit.bats has details):" >&2
    tail -n +2 "$marker" >&2
    return 1
  fi
}

# Call from setup_file() in every bin/ test file.
xgm_setup_file() {
  refuse_root
  require_path_audit
}

# Builds the fake system tree and the sandbox PATH. Call from setup().
make_root() {
  refuse_root
  require_path_audit || fail "path audit failed; refusing to run bin/ scripts"
  ROOT="$BATS_TEST_TMPDIR/root"
  # Scripts use $ROOT unquoted, so the path must not contain spaces or glob characters.
  [[ "$ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail "unsafe sandbox path for unquoted \$ROOT: $ROOT"

  LOG_DIR="$BATS_TEST_TMPDIR/homebrew/logs"
  DATA_DIR="$BATS_TEST_TMPDIR/homebrew/data/xgmobile-manager"
  SHIM_LOG="$BATS_TEST_TMPDIR/shim.log"
  SHIM_STATE="$BATS_TEST_TMPDIR/shim-state"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  OPTBIN="$BATS_TEST_TMPDIR/optbin"

  mkdir -p "$LOG_DIR" "$DATA_DIR" "$SHIM_STATE/active" "$SYSBIN" "$OPTBIN" "$BATS_TEST_TMPDIR/home" \
    "$ROOT/sys/devices/platform/asus-nb-wmi" "$ROOT/sys/bus/pci" "$ROOT/sys/class/dmi/id" \
    "$ROOT/sys/class/drm/card0/device" "$ROOT/dev/dri" \
    "$ROOT/etc/systemd/system" "$ROOT/etc/modprobe.d" "$ROOT/etc/sudoers.d" \
    "$ROOT/usr/share/vulkan/icd.d" "$ROOT/usr/share/vulkan/implicit_layer.d" "$ROOT/usr/share/vulkan/explicit_layer.d" \
    "$ROOT/usr/share/glvnd/egl_vendor.d" "$ROOT/usr/share/X11/xorg.conf.d" \
    "$ROOT/usr/local/bin" "$ROOT/usr/bin" "$ROOT/usr/lib/systemd/system" "$ROOT/home/xgmtest"
  # The primary user is "xgmtest" (see shims/ps), a name that can't exist on a real host.
  : > "$SHIM_LOG"

  local tool path
  for tool in "${SANDBOX_TOOLS[@]}"; do
    path="$(type -P "$tool")" || fail "required tool not found: $tool"
    ln -s "$path" "$SYSBIN/$tool"
  done

  # The iGPU is always present as card0 (AMD vendor ID).
  touch "$ROOT/dev/dri/card0" "$ROOT/dev/dri/renderD128"
  echo "0x1002" > "$ROOT/sys/class/drm/card0/device/vendor"
  echo 0 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo 0 > "$ROOT/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
  : > "$ROOT/sys/bus/pci/rescan"
  printf '%s\n' 'PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"' 'LANG=en_US.UTF-8' > "$ROOT/etc/environment"

  # Services and global commands already installed, so egpu-enable skips its self-repair block.
  ln -s "$XGM_REPO/bin/egpu-enable" "$ROOT/usr/local/bin/egpu-enable"
  touch "$ROOT/etc/systemd/system/nvidia-suspend.service"

  # steamos-readonly is on PATH by default; no_steamos_readonly removes it (CachyOS, Bazzite).
  ln -s "$XGM_OPTIONAL_SHIMS/steamos-readonly" "$OPTBIN/steamos-readonly"

  set_os steamos
  set_product "RC71L"
  set_connected 1
  nvidia_driver missing
  egpu_appears never
  set_lspci empty
}

set_os() {
  OS_TYPE="$1"
  case "$1" in
    steamos)        printf '%s\n' 'NAME="SteamOS"' 'ID=steamos' 'ID_LIKE=arch' 'VARIANT_ID=steamdeck' ;;
    cachyos)        printf '%s\n' 'NAME="CachyOS Linux"' 'ID=cachyos' 'ID_LIKE=arch' ;;
    bazzite)        printf '%s\n' 'NAME="Bazzite"' 'ID=bazzite' 'ID_LIKE="fedora"' 'VARIANT_ID=bazzite-deck' ;;
    bazzite-nvidia) printf '%s\n' 'NAME="Bazzite"' 'ID=bazzite' 'ID_LIKE="fedora"' 'VARIANT_ID=bazzite-deck-nvidia' ;;
    *) fail "set_os: unknown OS '$1'" ;;
  esac > "$ROOT/etc/os-release"
  case "$1" in
    cachyos) set_dm plasmalogin ;;
    *)       set_dm sddm ;;
  esac
}

# The display-manager.service alias: sddm (SteamOS, Bazzite) | plasmalogin (CachyOS Handheld) |
# none (no alias) | any other name, linked as-is. set_os picks the OS default.
set_dm() {
  local alias="$ROOT/etc/systemd/system/display-manager.service"
  rm -f "$alias"
  case "$1" in
    none) ;;
    sddm|plasmalogin)
      touch "$ROOT/usr/lib/systemd/system/$1.service"
      ln -s "$ROOT/usr/lib/systemd/system/$1.service" "$alias"
      ;;
    *) ln -s "$ROOT/usr/lib/systemd/system/$1" "$alias" ;;
  esac
}

set_product() { echo "$1" > "$ROOT/sys/class/dmi/id/product_name"; }

set_connected() { echo "$1" > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_connected"; }

# installed | missing
nvidia_driver() { echo "$1" > "$SHIM_STATE/nvidia_driver"; }

# Where the NVIDIA Vulkan/EGL configs currently live: backup (de-fanged by a previous eject,
# the normal state) | old (v0.2.0 location) | missing
nvidia_configs() {
  case "$1" in
    backup)
      mkdir -p "$DATA_DIR/configs_backup"
      echo '{"ICD": {"library_path": "libGLX_nvidia.so.0"}}' > "$DATA_DIR/configs_backup/nvidia_icd.json"
      echo '{"ICD": {"library_path": "libEGL_nvidia.so.0"}}' > "$DATA_DIR/configs_backup/10_nvidia.json"
      echo '{"layer": {"name": "VK_LAYER_NV_optimus"}}' > "$DATA_DIR/configs_backup/nvidia_layers.json"
      ;;
    old)
      mkdir -p "$ROOT/home/xgmtest/xgmobile_configs_backup"
      echo '{}' > "$ROOT/home/xgmtest/xgmobile_configs_backup/nvidia_icd.json"
      ;;
    missing) ;;
    *) fail "nvidia_configs: unknown state '$1'" ;;
  esac
}

# Which card shows up after egpu_enable is set to 1: nvidia | amd | never.
egpu_appears() {
  echo "$1" > "$SHIM_STATE/egpu_appears"
  [ "$1" = "nvidia" ] && set_lspci nvidia
  return 0
}

# Whether card1 disappears after egpu_enable is set to 0: yes | no
egpu_drops() { echo "$1" > "$SHIM_STATE/egpu_drops"; }

# nvidia | empty
set_lspci() { echo "$1" > "$SHIM_STATE/lspci"; }

# nvidia | amdgpu | none
set_lsmod() { echo "$1" > "$SHIM_STATE/lsmod"; }

# An already-enabled eGPU (for running eject/sync on their own).
egpu_present() {
  egpu_appears "$1"
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  env PATH="$SYSBIN" XGM_ROOT="$ROOT" SHIM_LOG=/dev/null SHIM_STATE="$SHIM_STATE" "$SYSBIN/bash" "$XGM_SHIMS/sleep"
}

supergfxd_active() { touch "$SHIM_STATE/active/supergfxd.service"; }

# Takes steamos-readonly off PATH, as on CachyOS and Bazzite.
no_steamos_readonly() { rm -f "$OPTBIN/steamos-readonly"; }

# Puts the supergfxctl shim on PATH; without this, `command -v supergfxctl` fails.
enable_supergfxctl() { ln -sf "$XGM_OPTIONAL_SHIMS/supergfxctl" "$OPTBIN/supergfxctl"; }

# run_script <bin name> [args...]
# Runs bin/<name> in a clean environment on the sandbox PATH. Sets bats' $status/$output, and
# $LOG to the contents of every log file the run wrote to LOG_DIR.
run_script() {
  local name="$1"
  shift
  [ -n "${ROOT:-}" ] || fail "run_script: call make_root first"
  find "$LOG_DIR" -mindepth 1 -delete
  run env -i \
    HOME="$BATS_TEST_TMPDIR/home" \
    LANG=C \
    PATH="$XGM_SHIMS:$OPTBIN:$SYSBIN" \
    XGM_ROOT="$ROOT" \
    SHIM_LOG="$SHIM_LOG" \
    SHIM_STATE="$SHIM_STATE" \
    FAKE_SUPERGFX_RC="${FAKE_SUPERGFX_RC:-0}" \
    "$SYSBIN/bash" "$XGM_REPO/bin/$name" "$@"
  LOG="$(find "$LOG_DIR" -type f -name '*.log' -exec cat {} + 2>/dev/null)"
}

# run_plugin_script <bin name> <vendor>: the argument order main.py uses.
run_plugin_script() {
  run_script "$1" "$2" "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"
}

# assert_called "<cmd> <args>": exact line match in the shim log.
assert_called() {
  grep -Fxq -- "$1" "$SHIM_LOG" || fail "$(printf 'expected call:\n  %s\nactual calls:\n%s' "$1" "$(sed 's/^/  /' "$SHIM_LOG")")"
}

# refute_called "<cmd> [args]": no call equal to, or starting with, the given text.
refute_called() {
  local line
  while IFS= read -r line; do
    if [ "$line" = "$1" ] || [[ "$line" == "$1 "* ]]; then
      fail "$(printf 'unexpected call:\n  %s\nactual calls:\n%s' "$line" "$(sed 's/^/  /' "$SHIM_LOG")")"
    fi
  done < "$SHIM_LOG"
}

# assert_called_before "<first>" "<second>": both called, first one earlier.
assert_called_before() {
  assert_called "$1"
  assert_called "$2"
  local a b
  a=$(grep -Fxn -- "$1" "$SHIM_LOG" | head -n 1 | cut -d: -f1)
  b=$(grep -Fxn -- "$2" "$SHIM_LOG" | tail -n 1 | cut -d: -f1)
  [ "$a" -lt "$b" ] || fail "expected '$1' (line $a) before '$2' (line $b)"
}

# Lines of the shim log that start with the given text.
calls_matching() { grep -F -- "$1" "$SHIM_LOG" || true; }
