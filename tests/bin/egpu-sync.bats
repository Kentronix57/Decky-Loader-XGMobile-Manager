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

@test "egpu_enable 1 but no eGPU PCI device: sanitized, reason logged" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_sync
  assert_success
  [[ "$LOG" == *"XG Mobile not active: egpu_enable is 1 but no eGPU PCI device was found."* ]]
  [[ "$LOG" == *"Boot safety net: XG Mobile not active, cleaned eGPU environment"* ]]
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
}

@test "egpu_enable 1 but egpu_connected 0: sanitized, reason logged" {
  egpu_present nvidia
  set_connected 0
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_sync
  assert_success
  [[ "$LOG" == *"XG Mobile not active: egpu_enable is 1 but the XG Mobile isn't connected (egpu_connected=0)."* ]]
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
}

@test "egpu_enable 0: reason logged" {
  run_sync
  assert_success
  [[ "$LOG" == *"XG Mobile not active: egpu_enable is 0."* ]]
}

@test "active, NVIDIA driver not bound yet (no DRM card), no record: PCI fallback still finds the eGPU" {
  egpu_present nvidia
  # Unbound, as in real sysfs: no class/drm entries and no drm/ dir under the PCI device.
  rm -rf "$ROOT/sys/class/drm/card1" "$ROOT/sys/class/drm/renderD129" "$(fake_gpu_pci_dir "$FAKE_EGPU_PCI_ADDR")/drm"
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_sync
  # Active, not sanitized: the eGPU is on the bus, only its card node is missing.
  assert_failure 1
  [[ "$LOG" == *"Failed to detect both GPUs"* ]]
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 1
}

@test "recorded address that isn't a display controller: no fallback, sanitized" {
  # Something else (a USB controller) now sits at the recorded address. The boot safety net
  # trusts the record: a wrong sanitize is recoverable (Enable again), a wrong eGPU isn't.
  local dev="$ROOT/sys/devices/pci0000:00/0000:00:08.3/0000:09:00.0"
  mkdir -p "$dev"
  echo 0x0c0330 > "$dev/class"
  ln -s "$dev" "$ROOT/sys/bus/pci/devices/0000:09:00.0"
  record_egpu_pci 0000:09:00.0
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_sync
  assert_success
  [[ "$LOG" == *"no eGPU PCI device was found"* ]]
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
}

@test "Flow laptop, XG Mobile absent but egpu_enable 1: the internal NVIDIA dGPU isn't taken for it" {
  # The internal dGPU is a display controller that isn't the boot VGA device, like the eGPU.
  fake_gpu_add 0000:02:00.0 0x10de 0 card2 renderD130
  record_egpu_pci
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/xgmtest/.config/plasma-workspace/env"
  touch "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  run_sync
  assert_success
  [[ "$LOG" == *"XG Mobile not active: egpu_enable is 1 but no eGPU PCI device was found."* ]]
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
}

@test "primary user: Steam running as deck stays deck" {
  steam_user deck
  run_sync
  assert_success
  [[ "$LOG" == *"Primary user: deck"* ]]
}
