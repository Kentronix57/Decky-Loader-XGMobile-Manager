#!/usr/bin/env bats
# bin/egpu-eject: undoes everything egpu-enable did, and the card-drop wait.

setup_file() {
  load helpers/sandbox
  refuse_root
}

setup() {
  load helpers/sandbox
  make_root
}

# Every `set-environment VAR=...` (system or --user) has a matching `unset-environment VAR`.
assert_env_symmetry() {
  local line scope var
  while IFS= read -r line; do
    scope="systemctl"
    [[ "$line" == "systemctl --user "* ]] && scope="systemctl --user"
    var="${line#"$scope set-environment "}"
    var="${var%%=*}"
    assert_called "$scope unset-environment $var"
  done < <(grep -E '^systemctl (--user )?set-environment ' "$SHIM_LOG")
}

enable_then_eject() {
  local vendor="$1"
  run_plugin_script egpu-enable "$vendor"
  assert_success
  run_plugin_script egpu-eject "$vendor"
  assert_success
}

symmetry_nvidia() {
  set_os "$1"
  nvidia_driver installed
  nvidia_configs backup
  egpu_appears nvidia
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"

  enable_then_eject nvidia

  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_env_symmetry
  assert_called "systemctl unset-environment WLR_DRM_DEVICES"
  assert [ -f "$DATA_DIR/configs_backup/nvidia_icd.json" ]
  assert [ -f "$DATA_DIR/configs_backup/10_nvidia.json" ]
  assert [ -f "$DATA_DIR/configs_backup/nvidia_layers.json" ]
  assert [ ! -e "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  assert [ ! -e "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ ! -e "$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert [ ! -e "$ROOT/etc/modprobe.d/nvidia-egpu.conf" ]
  assert_called "modprobe -r nvidia"
  assert_called "systemctl disable xgmobile-boot-sync.service"
  [[ "$LOG" == *"Success! DRM card count dropped to 1"* ]]
}

symmetry_amd() {
  set_os "$1"
  egpu_appears amd
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"

  enable_then_eject amd

  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_env_symmetry
  assert_called "systemctl unset-environment WLR_DRM_DEVICES"
  assert_called "systemctl --user unset-environment WLR_DRM_DEVICES"
  refute_called "modprobe"
  [[ "$LOG" == *"Success! DRM card count dropped to 1"* ]]
}

@test "symmetry: enable then eject, steamos/nvidia" {
  symmetry_nvidia steamos
}

@test "symmetry: enable then eject, cachyos/nvidia" {
  symmetry_nvidia cachyos
}

@test "symmetry: enable then eject, steamos/amd" {
  symmetry_amd steamos
}

@test "symmetry: enable then eject, cachyos/amd" {
  symmetry_amd cachyos
}

@test "card count drops: success logged, sddm restarted, egpu_enable cleared" {
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"Success! DRM card count dropped to 1. eGPU safely detached."* ]]
  [[ "$LOG" != *"WARNING"* ]]
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
  assert_called_before "systemctl stop sddm" "systemctl start sddm"
  assert_equal "$(readlink "$LOG_DIR/xgmobile_manager_eject_latest.log")" "$LOG_DIR/xgmobile_manager_eject_amd.log"
}

@test "card count doesn't drop: WARNING logged, still exit 0 and sddm restarted" {
  egpu_present amd
  egpu_drops no
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"WARNING: Hardware did not seem to drop from /dev/dri/."* ]]
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 15
  assert_called "systemctl start sddm"
}

@test "bazzite/nvidia: modules unloaded, /etc/environment and configs untouched" {
  set_os bazzite-nvidia
  egpu_present nvidia
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_success
  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_called "modprobe -r nvidia_drm"
  assert_called "systemctl disable nvidia-powerd nvidia-persistenced"
  assert_called "systemctl unset-environment GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT"
  refute_called "steamos-readonly"
}

@test "Flow laptop + supergfxctl: supergfxd re-enabled" {
  set_product "ROG Flow X13 GV301QH"
  enable_supergfxctl
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert_called "systemctl enable supergfxd.service"
}

@test "Ally + supergfxctl: supergfxd disabled" {
  enable_supergfxctl
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert_called "systemctl disable supergfxd.service"
}
