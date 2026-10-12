#!/usr/bin/env bats
# bin/egpu-sync: the boot safety net (xgmobile-boot-sync.service). It runs with no arguments at
# boot; the tests pass the log and data dirs, so nothing is read or written outside the sandbox.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
}

run_sync() { run_script egpu-sync "$LOG_DIR" "$DATA_DIR"; }

# The OS as the service sees it: no steamos-readonly on CachyOS/Bazzite.
boot_os() {
  set_os "$1"
  [ "$1" != "steamos" ] && no_steamos_readonly
  return 0
}

# Powered off while enabled, then booted without the XG Mobile: the eGPU is off and gone, and
# Steam isn't running yet.
power_off_without_xgm() {
  echo 0 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  env PATH="$SYSBIN" XGM_ROOT="$ROOT" SHIM_LOG=/dev/null SHIM_STATE="$SHIM_STATE" "$SYSBIN/bash" "$XGM_SHIMS/sleep"
  assert [ ! -e "$ROOT/sys/class/drm/card1" ]
  steam_not_running
  : > "$SHIM_LOG"
}

cold_boot_symmetry() {
  boot_os "$1"
  nvidia_driver installed
  nvidia_configs backup
  egpu_appears nvidia
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-enable nvidia
  assert_success
  assert [ -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert [ -e "$ROOT/etc/modprobe.d/nvidia-egpu.conf" ]
  touch "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-kwin.sh"

  power_off_without_xgm
  run_sync
  assert_success

  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  local var
  for var in MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT; do
    assert_called "systemctl unset-environment $var"
    assert_called "systemctl --user unset-environment $var"
  done
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-kwin.sh" ]
  assert [ ! -e "$ROOT/etc/modprobe.d/nvidia-egpu.conf" ]
  refute_called "systemctl disable"
  [[ "$LOG" == *"Primary user: xgmtest"* ]]
  [[ "$LOG" == *"Boot safety net: XG Mobile not active, cleaned eGPU environment"* ]]
}

@test "cold boot without the XG Mobile after enable, steamos/nvidia: everything enable injected is undone" {
  cold_boot_symmetry steamos
}

@test "cold boot without the XG Mobile after enable, cachyos/nvidia: everything enable injected is undone" {
  cold_boot_symmetry cachyos
}

@test "inactive at early boot (no user session yet): user manager skipped silently" {
  steam_not_running
  no_user_session
  echo "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" >> "$ROOT/etc/environment"
  run_sync
  assert_success
  assert_called "systemctl unset-environment VK_ICD_FILENAMES"
  refute_called "sudo"
  refute_called "systemctl --user"
  run grep -c VK_ICD_FILENAMES "$ROOT/etc/environment"
  assert_output 0
}

@test "inactive: egpu_enable missing counts as not active" {
  rm -f "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_sync
  assert_success
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
}

@test "inactive: only exact keys are removed from /etc/environment" {
  printf '%s\n' 'MY_WLR_DRM_DEVICES=keep' '# WLR_DRM_DEVICES=keep' 'WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0' >> "$ROOT/etc/environment"
  run_sync
  assert_success
  run cat "$ROOT/etc/environment"
  assert_line 'MY_WLR_DRM_DEVICES=keep'
  assert_line '# WLR_DRM_DEVICES=keep'
  refute_line 'WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0'
}

@test "Steam not running: primary user is the first uid >= 1000 with a home dir" {
  steam_not_running
  # nohome (uid 1000) has no home dir, nobody (65534) is out of range.
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"
  touch "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  run_sync
  assert_success
  [[ "$LOG" == *"Primary user: xgmtest"* ]]
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
}

@test "no arguments: logs to the plugin's log dir next to the plugin" {
  # Lay out a fake homebrew tree in the sandbox and run the script from there.
  local homebrew="$BATS_TEST_TMPDIR/hb" dir
  dir="$homebrew/plugins/xgmobile-manager/bin"
  mkdir -p "$dir" "$homebrew/logs"
  cp "$XGM_REPO/bin/egpu-sync" "$XGM_REPO/bin/xgm-common.sh" "$dir/"
  XGM_BIN_DIR="$dir" run_script egpu-sync
  assert_success
  assert_equal "$output" ""
  run cat "$homebrew/logs/xgmobile_manager_boot_sync.log"
  assert_line --partial "Boot safety net: XG Mobile not active"
}

@test "active + nvidia: WLR_DRM_DEVICES rewritten and kwin env refreshed" {
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"

  run_sync
  assert_success

  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run cat "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  assert_line "export KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
  refute_called "systemctl unset-environment"
  refute_called "systemctl disable"
}

@test "active + nvidia, eGPU as card0 (as captured on the Ally): nodes resolved by PCI address" {
  gpu_numbering card1 renderD128 card0 renderD129
  record_egpu_pci
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"
  run_sync
  assert_success
  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1"
}

@test "active + nvidia, eGPU as card0, no record: boot_vga fallback finds it" {
  gpu_numbering card1 renderD128 card0 renderD129
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"
  run_sync
  assert_success
  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1"
}

@test "active: recorded PCI address wins over boot_vga" {
  egpu_present nvidia
  echo 1 > "$ROOT/sys/class/drm/card1/device/boot_vga"
  record_egpu_pci
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"
  run_sync
  assert_success
  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
}

@test "active + nvidia on cachyos without steamos-readonly: WLR_DRM_DEVICES still rewritten, exit 0" {
  boot_os cachyos
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"

  run_sync
  assert_success

  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  refute_called "steamos-readonly"
}

@test "active + amd eGPU (not 0x10de): skipped cleanly, environment untouched" {
  egpu_present amd
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  local before
  before="$(cat "$ROOT/etc/environment")"
  run_sync
  assert_success
  [[ "$LOG" == *"Skipped cleanly"* ]]
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"
  refute_called "steamos-readonly"
  refute_called "systemctl"
}

@test "active + nvidia with no iGPU card: exit 1, environment untouched" {
  egpu_present nvidia
  rm -rf "$ROOT/sys/class/drm/card0"
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  local before
  before="$(cat "$ROOT/etc/environment")"
  run_sync
  assert_failure 1
  [[ "$LOG" == *"Failed to detect both GPUs"* ]]
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"
}

@test "bazzite: no-op, exit 0, even with the XG Mobile off" {
  boot_os bazzite-nvidia
  echo "GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT=1" >> "$ROOT/etc/environment"
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_sync
  assert_success
  [[ "$LOG" == *"bazzite-nvidia: egpu-enable doesn't inject the eGPU environment here. Skipping."* ]]
  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  refute_called "systemctl"
}

@test "unsupported OS: no-op, exit 0" {
  printf '%s\n' 'NAME="Ubuntu"' 'ID=ubuntu' > "$ROOT/etc/os-release"
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_sync
  assert_success
  [[ "$LOG" == *"OS: unsupported"* ]]
  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  refute_called "systemctl"
}

@test "OS detection follows main.py get_os_type" {
  local os
  for os in steamos cachyos bazzite bazzite-nvidia; do
    set_os "$os"
    run_sync
    [[ "$LOG" == *"OS: $os"* ]] || fail "expected OS: $os, log was: $LOG"
  done
}
