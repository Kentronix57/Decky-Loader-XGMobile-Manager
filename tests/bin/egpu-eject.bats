#!/usr/bin/env bats
# bin/egpu-eject: undoes everything egpu-enable did, and the card-drop wait.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
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

# CachyOS runs the symmetry tests the way CachyOS Handheld ships: plasmalogin as the display
# manager and no steamos-readonly.
os_like_hardware() {
  set_os "$1"
  [ "$1" = "cachyos" ] && no_steamos_readonly
  return 0
}

assert_dm_cycled() {
  local dm=sddm.service
  [ "$1" = "cachyos" ] && dm=plasmalogin.service
  assert_equal "$(calls_matching "systemctl stop $dm" | wc -l)" 2
  assert_equal "$(calls_matching "systemctl start $dm" | wc -l)" 2
  if [ "$1" = "cachyos" ]; then
    assert_equal "$(calls_matching sddm)" ""
    refute_called "steamos-readonly"
    [[ "$LOG" != *"command not found"* ]]
  fi
}

symmetry_nvidia() {
  os_like_hardware "$1"
  nvidia_driver installed
  nvidia_configs backup
  egpu_appears nvidia
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"

  enable_then_eject nvidia

  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_env_symmetry
  assert_called "systemctl unset-environment WLR_DRM_DEVICES"
  if [ "$1" = "cachyos" ]; then
    # Enable repaired the configs an older version moved out; eject leaves the pacman-owned files.
    assert [ -f "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
    assert [ -f "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
    assert [ -f "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json" ]
    assert [ ! -e "$DATA_DIR/configs_backup/nvidia_icd.json" ]
    assert [ ! -e "$DATA_DIR/configs_backup/10_nvidia.json" ]
  else
    assert [ -f "$DATA_DIR/configs_backup/nvidia_icd.json" ]
    assert [ -f "$DATA_DIR/configs_backup/10_nvidia.json" ]
    assert [ -f "$DATA_DIR/configs_backup/nvidia_layers.json" ]
    assert [ ! -e "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
    assert [ ! -e "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  fi
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert [ ! -e "$ROOT/etc/modprobe.d/nvidia-egpu.conf" ]
  assert_called "modprobe -r nvidia"
  assert_called "systemctl disable xgmobile-boot-sync.service"
  [[ "$LOG" == *"Success! DRM card count dropped to 1"* ]]
  assert_dm_cycled "$1"
}

symmetry_amd() {
  os_like_hardware "$1"
  egpu_appears amd
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"

  enable_then_eject amd

  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_env_symmetry
  assert_called "systemctl unset-environment WLR_DRM_DEVICES"
  assert_called "systemctl --user unset-environment WLR_DRM_DEVICES"
  refute_called "modprobe"
  [[ "$LOG" == *"Success! DRM card count dropped to 1"* ]]
  assert_dm_cycled "$1"
}

@test "symmetry: enable then eject, steamos/nvidia" {
  symmetry_nvidia steamos
  # Enable: boot service install + re-fang. Eject: de-fang.
  assert_equal "$(calls_matching 'steamos-readonly disable' | wc -l)" 3
  assert_equal "$(calls_matching 'steamos-readonly enable' | wc -l)" 3
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
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_equal "$(readlink "$LOG_DIR/xgmobile_manager_eject_latest.log")" "$LOG_DIR/xgmobile_manager_eject_amd.log"
}

@test "cachyos + plasmalogin: plasmalogin stopped then started, sddm never touched" {
  set_os cachyos
  no_steamos_readonly
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"Display manager: plasmalogin.service"* ]]
  assert_called_before "systemctl stop plasmalogin.service" "systemctl start plasmalogin.service"
  assert_equal "$(calls_matching sddm)" ""
  refute_called "steamos-readonly"
  [[ "$LOG" != *"command not found"* ]]
}

@test "steamos/nvidia: sddm.service, configs de-fanged inside steamos-readonly" {
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"Display manager: sddm.service"* ]]
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
}

# NVIDIA configs as pacman installs them, before any eject.
nvidia_configs_installed() {
  echo '{"ICD": {"library_path": "libGLX_nvidia.so.0"}}' > "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json"
  echo '{"ICD": {"library_path": "libEGL_nvidia.so.0"}}' > "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json"
  echo '{"layer": {"name": "VK_LAYER_NV_optimus"}}' > "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json"
}

@test "cachyos/nvidia: pacman-owned NVIDIA configs are left in place" {
  set_os cachyos
  no_steamos_readonly
  nvidia_configs_installed
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  assert [ -f "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  assert [ -f "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ -f "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json" ]
  assert [ ! -e "$DATA_DIR/configs_backup/nvidia_icd.json" ]
  [[ "$LOG" == *"owned by pacman packages, leaving them in place"* ]]
  [[ "$LOG" != *"De-fanging"* ]]
}

@test "steamos/nvidia: NVIDIA configs are still moved to the backup" {
  nvidia_configs_installed
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  assert [ ! -e "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  assert [ ! -e "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ -f "$DATA_DIR/configs_backup/nvidia_icd.json" ]
  assert [ -f "$DATA_DIR/configs_backup/10_nvidia.json" ]
  [[ "$LOG" == *"De-fanging NVIDIA configs"* ]]
}

@test "no display-manager alias: falls back to sddm.service" {
  set_os cachyos
  set_dm none
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
}

@test "card count doesn't drop: WARNING logged, still exit 0 and sddm restarted" {
  egpu_present amd
  egpu_drops no
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"WARNING: Hardware did not seem to drop from /dev/dri/."* ]]
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 15
  assert_called "systemctl start sddm.service"
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
