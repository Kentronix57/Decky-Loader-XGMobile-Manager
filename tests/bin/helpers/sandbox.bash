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
# shellcheck source=fake_gpu.bash
source "$XGM_REPO/tests/bin/helpers/fake_gpu.bash"
# shellcheck source=timeline.bash
source "$XGM_REPO/tests/bin/helpers/timeline.bash"

# Real tools the scripts (and the shims) are allowed to use.
SANDBOX_TOOLS=(bash env cat grep sed awk ls mkdir mv rm ln chmod cp head tail wc xargs cut tr echo date readlink dirname basename touch sort true false printf tee install)

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

  LOG_DIR="$BATS_TEST_TMPDIR/homebrew/logs/xgmobile-manager/activity"
  DATA_DIR="$BATS_TEST_TMPDIR/homebrew/data/xgmobile-manager"
  SHIM_LOG="$BATS_TEST_TMPDIR/shim.log"
  SHIM_STATE="$BATS_TEST_TMPDIR/shim-state"
  SYSBIN="$BATS_TEST_TMPDIR/sysbin"
  OPTBIN="$BATS_TEST_TMPDIR/optbin"

  mkdir -p "$LOG_DIR" "$DATA_DIR" "$SHIM_STATE/active" "$SYSBIN" "$OPTBIN" "$BATS_TEST_TMPDIR/home" \
    "$ROOT/sys/devices/platform/asus-nb-wmi" "$ROOT/sys/bus/pci" "$ROOT/sys/class/dmi/id" \
    "$ROOT/sys/class/drm" "$ROOT/dev/dri" \
    "$ROOT/etc/systemd/system" "$ROOT/etc/modprobe.d" "$ROOT/etc/sudoers.d" \
    "$ROOT/usr/share/vulkan/icd.d" "$ROOT/usr/share/vulkan/implicit_layer.d" "$ROOT/usr/share/vulkan/explicit_layer.d" \
    "$ROOT/usr/share/glvnd/egl_vendor.d" "$ROOT/usr/share/X11/xorg.conf.d" \
    "$ROOT/usr/local/bin" "$ROOT/usr/bin" "$ROOT/usr/lib/systemd/system" "$ROOT/home/xgmtest" \
    "$ROOT/sys/module" "$ROOT/run/user/64999"
  # The primary user is "xgmtest" (see shims/ps), a name that can't exist on a real host. Its uid
  # (shims/id) is 64999, and it has a runtime dir with a user bus, as when a session is running.
  # The bus is a real socket (egpu-eject checks -S): a hard link to a template the bus timeline
  # reuses. Bound from inside the dir, since socket paths are limited to 108 bytes.
  (cd "$SHIM_STATE" && python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("bus.sock")') \
    || fail "couldn't create the template bus socket"
  ln -f "$SHIM_STATE/bus.sock" "$ROOT/run/user/64999/bus"
  : > "$SHIM_LOG"
  # The fake wall clock the waits read (XGM_FAKE_CLOCK); the sleep shim moves it forward. It starts
  # at 1000 s so that a clock_step back stays positive, like a real one.
  echo 1000 > "$SHIM_STATE/clock"

  local tool path
  for tool in "${SANDBOX_TOOLS[@]}"; do
    path="$(type -P "$tool")" || fail "required tool not found: $tool"
    ln -s "$path" "$SYSBIN/$tool"
  done

  # The iGPU is always present: card0/renderD128/fb0 unless gpu_numbering says otherwise.
  gpu_numbering card0 renderD128 card1 renderD129
  # Framebuffers and consoles as captured on CachyOS: no fbcon attached, only the dummy console.
  mkdir -p "$ROOT/proc" "$ROOT/sys/class/vtconsole/vtcon0"
  printf '%s\n' '0 amdgpudrmfb' '1 nvidia-drmdrmfb' > "$ROOT/proc/fb"
  echo "(S) dummy device" > "$ROOT/sys/class/vtconsole/vtcon0/name"
  echo 1 > "$ROOT/sys/class/vtconsole/vtcon0/bind"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'nobody:x:65534:65534::/:/usr/bin/nologin' \
    'nohome:x:1000:1000::/home/nohome:/bin/bash' 'xgmtest:x:64999:64999::/home/xgmtest:/bin/bash' > "$ROOT/etc/passwd"
  echo 0 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo 0 > "$ROOT/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
  : > "$ROOT/sys/bus/pci/rescan"
  printf '%s\n' 'PATH="/usr/local/sbin:/usr/local/bin:/usr/bin"' 'LANG=en_US.UTF-8' > "$ROOT/etc/environment"

  # Services and global commands already installed, so egpu-enable skips its self-repair block.
  ln -s "$XGM_REPO/bin/egpu-enable" "$ROOT/usr/local/bin/egpu-enable"
  touch "$ROOT/etc/systemd/system/nvidia-suspend.service"

  # steamos-readonly is on PATH by default; no_steamos_readonly removes it (CachyOS, Bazzite).
  ln -s "$XGM_OPTIONAL_SHIMS/steamos-readonly" "$OPTBIN/steamos-readonly"
  # setpriv (util-linux) is on PATH by default; no_setpriv removes it.
  ln -s "$XGM_OPTIONAL_SHIMS/setpriv" "$OPTBIN/setpriv"

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

# The display-manager.service alias: set_dm <name> [dangling]. <name> is sddm | plasmalogin | gdm
# | ... (".service" is appended unless the name already has a suffix, e.g. bogus.target), or none
# for no alias. The target unit file is created, or removed if "dangling" is given. set_os picks the OS
# default: plasmalogin on cachyos, sddm otherwise.
set_dm() {
  local alias="$ROOT/etc/systemd/system/display-manager.service" unit="$1"
  rm -f "$alias"
  [ "$1" = "none" ] && return 0
  [[ "$unit" == *.* ]] || unit="$unit.service"
  if [ "${2:-}" = "dangling" ]; then
    rm -f "$ROOT/usr/lib/systemd/system/$unit"
  else
    touch "$ROOT/usr/lib/systemd/system/$unit"
  fi
  ln -s "$ROOT/usr/lib/systemd/system/$unit" "$alias"
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

# gpu_numbering <iGPU card> <iGPU render> <eGPU card> <eGPU render> [<iGPU fb> <eGPU fb>]: the
# DRM and fb node numbers (fb0/fb1 by default), which aren't stable across boots on real hardware
# (the XG Mobile shows up as card0 or card1). Rebuilds the iGPU (always present); the eGPU gets
# its numbers when it appears (shims/sleep).
gpu_numbering() {
  fake_gpu_remove "$FAKE_IGPU_PCI_ADDR"
  fake_gpu_add "$FAKE_IGPU_PCI_ADDR" 0x1002 1 "$1" "$2" "${5:-fb0}"
  echo "$3 $4 ${6:-fb1}" > "$SHIM_STATE/egpu_nodes"
}

# record_egpu_pci [address]: the eGPU PCI address egpu-enable records (default: the fake eGPU's).
record_egpu_pci() { echo "${1:-$FAKE_EGPU_PCI_ADDR}" > "$DATA_DIR/egpu_pci_address"; }

# Whether the eGPU disappears after egpu_enable is set to 0: yes | no
egpu_drops() { echo "$1" > "$SHIM_STATE/egpu_drops"; }

# nvidia | empty
set_lspci() { echo "$1" > "$SHIM_STATE/lspci"; }

# nvidia | amdgpu | none
set_lsmod() { echo "$1" > "$SHIM_STATE/lsmod"; }

# pacman packages (shims/pacman). pacman_repo <pkg> none | <record>...: what `pacman -Si` finds in
# the sync database, one record per argument in repo priority order. A record is <version>
# (repo "cachyos") or <repo>=<version>. pacman_local <pkg> <version|none>: what `pacman -Q`
# reports as installed. Once pacman_repo is used, `pacman -Si` only finds packages set this way.
pacman_repo() {
  local pkg="$1" rec
  shift
  mkdir -p "$SHIM_STATE/pacman_repo"
  rm -f "$SHIM_STATE/pacman_repo/$pkg"
  [ "$1" = "none" ] && return 0
  for rec in "$@"; do
    if [[ "$rec" == *=* ]]; then
      echo "${rec%%=*} ${rec#*=}"
    else
      echo "cachyos $rec"
    fi
  done > "$SHIM_STATE/pacman_repo/$pkg"
}

pacman_local() {
  mkdir -p "$SHIM_STATE/pacman_local"
  if [ "$2" = "none" ]; then rm -f "$SHIM_STATE/pacman_local/$1"; else echo "$2" > "$SHIM_STATE/pacman_local/$1"; fi
}

# Exit code of `pacman -S` (default 0).
pacman_install_rc() { echo "$1" > "$SHIM_STATE/pacman_install_rc"; }

# installed_kernel <kver> <pkgbase> [version]: a kernel package with its module dir and pkgbase
# file, installed at <version> (default 7.2.9-2), and the same version in the sync database.
installed_kernel() {
  mkdir -p "$ROOT/usr/lib/modules/$1"
  echo "$2" > "$ROOT/usr/lib/modules/$1/pkgbase"
  pacman_local "$2" "${3:-7.2.9-2}"
  pacman_repo "$2" "${3:-7.2.9-2}"
}

# nvidia_module_for <kver>: `modinfo -k <kver> nvidia` succeeds.
nvidia_module_for() { mkdir -p "$SHIM_STATE/modinfo_k"; touch "$SHIM_STATE/modinfo_k/$1"; }

# An already-enabled eGPU (for running eject/sync on their own).
egpu_present() {
  egpu_appears "$1"
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  env PATH="$SYSBIN" XGM_ROOT="$ROOT" SHIM_LOG=/dev/null SHIM_STATE="$SHIM_STATE" "$SYSBIN/bash" "$XGM_SHIMS/sleep"
}

# egpu_card_later [n]: the eGPU is on the bus but nvidia-drm hasn't registered its DRM card yet
# (as at boot). It appears n sleep calls from now (shims/sleep), or during a `udevadm wait`
# (udevadm_wait). Without n, only udevadm wait makes it appear.
egpu_card_later() {
  fake_gpu_drm_remove "$FAKE_EGPU_PCI_ADDR"
  rm -f "$SHIM_STATE/egpu_card_at"
  [ -n "${1:-}" ] && echo $(($(tl_tick) + $1)) > "$SHIM_STATE/egpu_card_at"
  return 0
}

# udevadm_wait appears|timeout|missing: what `udevadm wait` does (shims/udevadm).
udevadm_wait() { echo "$1" > "$SHIM_STATE/udevadm_wait"; }

# gpu_holders <n|ignore-term|unkillable>: the next n fuser checks find the eGPU nodes in use
# (any fuser -k frees them); or they're in use until fuser -k -KILL (ignore-term); or they stay in
# use whatever happens. See shims/fuser.
gpu_holders() { echo "$1" > "$SHIM_STATE/gpu_holders"; }

# module_stuck <module>: `modprobe -r <module>` fails as "in use" and its sys/module dir stays.
module_stuck() { echo "$1" >> "$SHIM_STATE/module_stuck"; }

# Boot without a session: Steam isn't running (shims/ps prints nothing) and the primary user has
# no runtime dir.
steam_not_running() { touch "$SHIM_STATE/steam_not_running"; }
no_user_session() { rm -rf "$ROOT/run/user/64999"; }

# manager_env <system|user> NAME=value...: variables already in that systemd manager's environment
# (shims/systemctl), e.g. what a Plasma session imported.
manager_env() {
  local scope="$1"
  shift
  mkdir -p "$SHIM_STATE/env"
  printf '%s\n' "$@" >> "$SHIM_STATE/env/$scope"
}

# user_initial_env NAME=value...: variables the user manager started with (from /etc/environment
# at boot). show-environment lists them, but unset-environment can't remove them; only stopping
# or killing user@64999.service does (shims/systemctl).
user_initial_env() {
  mkdir -p "$SHIM_STATE/env"
  printf '%s\n' "$@" >> "$SHIM_STATE/env/user_initial"
}

# manager_env_of <system|user>: that manager's environment now, one NAME=value per line.
manager_env_of() { cat "$SHIM_STATE/env/$1" 2>/dev/null || true; }

# The primary user has a runtime dir, but its user manager doesn't answer (every --user call fails).
user_manager_down() { touch "$SHIM_STATE/user_manager_down"; }

# session_ready now|never|<n>|activating:<n>: when the user's graphical-session.target is active
# (shims/systemctl): right away (the default), never, after <n> inactive checks, or after <n>
# checks that answer "activating".
session_ready() { echo "$1" > "$SHIM_STATE/session_ready"; }

# timeline <key> "<tick> <value>"...: scripts how a piece of the user session changes over time
# (helpers/timeline.bash has the keys). Every sleep call is one tick; tick 0 is the start. The
# runtime dir and bus keys are applied to the tree right away for tick 0.
timeline() {
  local key="$1"
  shift
  mkdir -p "$SHIM_STATE/timeline"
  printf '%s\n' "$@" > "$SHIM_STATE/timeline/$key"
  tl_apply_fs "$ROOT"
}

# manager_after <event> "<ticks later> <state>[:<id>]"...: what user@64999.service does after an
# event (shims/systemctl): kill (`systemctl kill -s KILL user@64999.service`), stop (`systemctl
# stop user@64999.service`), unit-kill (a stuck
# unit killed), list-units (its deactivating units listed) or show:<n> (the n-th `show` of it).
# Without it, a killed or stopped manager is inactive and the other events change nothing.
manager_after() {
  local event="${1//-/_}"
  event="${event//:/_}"
  shift
  mkdir -p "$SHIM_STATE/timeline"
  printf '%s\n' "$@" > "$SHIM_STATE/timeline/manager.after_$event"
}

# clock_step <tick> <seconds>: the fake clock jumps by <seconds> (negative: back, as NTP can step
# it) when that tick is reached.
clock_step() { echo "$1 $2" >> "$SHIM_STATE/clock_steps"; }

# manager_call_cost <seconds>: every systemctl call to user@64999 takes that long (fake clock)
# while it's deactivating, as a hung manager's calls run into their timeout.
manager_call_cost() { echo "$1" > "$SHIM_STATE/manager_call_cost"; }

# stuck_unit <unit>: a unit the stopping user manager can't stop, until it's killed.
stuck_unit() { echo "$1" >> "$SHIM_STATE/stuck_units"; }

# The document portal's FUSE mount at run/user/64999/doc (shims/findmnt), until fusermount3 -u.
doc_mounted() { touch "$SHIM_STATE/doc_mounted"; }

# steam_user <name>: the user Steam runs as (shims/ps), instead of xgmtest.
steam_user() { echo "$1" > "$SHIM_STATE/steam_user"; }

# The boot service as egpu-enable installs it: unit file copied and enabled.
sync_service_installed() {
  cp "$XGM_REPO/assets/services/xgmobile-boot-sync.service" "$ROOT/etc/systemd/system/"
  ln -sfn "$(readlink -f "$XGM_REPO/bin/egpu-sync")" "$ROOT/usr/local/bin/egpu-sync"
  mkdir -p "$SHIM_STATE/enabled"
  touch "$SHIM_STATE/enabled/xgmobile-boot-sync.service"
}

supergfxd_active() { touch "$SHIM_STATE/active/supergfxd.service"; }

# Takes setpriv off PATH: the user manager calls fall back to sudo -u.
no_setpriv() { rm -f "$OPTBIN/setpriv"; }

# Takes steamos-readonly off PATH, as on CachyOS and Bazzite.
no_steamos_readonly() { rm -f "$OPTBIN/steamos-readonly"; }

# Puts the supergfxctl shim on PATH; without this, `command -v supergfxctl` fails.
enable_supergfxctl() { ln -sf "$XGM_OPTIONAL_SHIMS/supergfxctl" "$OPTBIN/supergfxctl"; }

# run_script <bin name> [args...]
# Runs bin/<name> (or $XGM_BIN_DIR/<name>) in a clean environment on the sandbox PATH, with
# LANG=C unless $SANDBOX_LANG is set, the fake clock (XGM_FAKE_CLOCK), and XGM_WAIT_POLL,
# XGM_WAIT_CAP, XGM_HUNG_AFTER, XGM_RESTART_CAP and XGM_CARD_WAIT if set. Sets bats' $status/$output, and
# $LOG to the contents of every log file the run wrote to LOG_DIR. LOG_DIR is emptied first,
# unless KEEP_LOG_DIR=1 (tests that seed it, e.g. migrate-logs).
run_script() {
  local name="$1"
  shift
  [ -n "${ROOT:-}" ] || fail "run_script: call make_root first"
  [ "${KEEP_LOG_DIR:-0}" = "1" ] || find "$LOG_DIR" -mindepth 1 -delete
  # The wait tunables (bin/xgm-common.sh, bin/egpu-sync) pass through when a test sets them.
  local var tunables=()
  for var in XGM_WAIT_POLL XGM_WAIT_CAP XGM_HUNG_AFTER XGM_RESTART_CAP XGM_CARD_WAIT; do
    [ -n "${!var:-}" ] && tunables+=("$var=${!var}")
  done
  run env -i \
    "${tunables[@]}" \
    HOME="$BATS_TEST_TMPDIR/home" \
    LANG="${SANDBOX_LANG:-C}" \
    PATH="$XGM_SHIMS:$OPTBIN:$SYSBIN" \
    XGM_ROOT="$ROOT" \
    SHIM_LOG="$SHIM_LOG" \
    SHIM_STATE="$SHIM_STATE" \
    XGM_FAKE_CLOCK="$SHIM_STATE/clock" \
    SHIM_SANDBOX="$BATS_TEST_TMPDIR" \
    SHIM_REAL_CHMOD="$SYSBIN/chmod" \
    FAKE_SUPERGFX_RC="${FAKE_SUPERGFX_RC:-0}" \
    "$SYSBIN/bash" "${XGM_BIN_DIR:-$XGM_REPO/bin}/$name" "$@"
  LOG="$(find "$LOG_DIR" -type f -name '*.log' -exec cat {} + 2>/dev/null)"

  # egpu-enable's self-repair block chmods the plugin's own bin/ files (the repo, not $ROOT). The
  # chmod shim refuses that; these make sure a test can't reach it without noticing.
  if [ -e "$SHIM_STATE/chmod_refused" ]; then
    fail "$(printf 'chmod outside the test sandbox was refused:\n%s' "$(cat "$SHIM_STATE/chmod_refused")")"
  fi
  if [[ "$LOG$output" == *"Initiating self-repair"* ]] && [ "${ALLOW_SELF_REPAIR:-0}" != "1" ]; then
    fail "$name reached the self-repair block, which touches the real plugin dir. Set ALLOW_SELF_REPAIR=1 only if the test needs it and nothing outside the sandbox is modified."
  fi
}

# run_without_helper <bin name> [args...]: runs a copy of bin/<name> from a temp bin dir that has
# no xgm-common.sh. The real bin/xgm-common.sh is never touched.
run_without_helper() {
  local dir="$BATS_TEST_TMPDIR/bin-nohelper"
  mkdir -p "$dir"
  cp "$XGM_REPO/bin/$1" "$dir/$1"
  [ ! -e "$dir/xgm-common.sh" ] || fail "run_without_helper: $dir/xgm-common.sh exists"
  XGM_BIN_DIR="$dir" run_script "$@"
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
