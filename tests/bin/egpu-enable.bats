#!/usr/bin/env bats
# bin/egpu-enable: exit codes, environment injection and per-OS branching.

setup_file() {
  load helpers/sandbox
  refuse_root
}

setup() {
  load helpers/sandbox
  make_root
}

NVIDIA_ENV_LINES() {
  printf '%s\n' \
    "MESA_VK_DEVICE_SELECT=10de:2717" \
    "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" \
    "WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0" \
    "VK_LOADER_LAYERS_DISABLE=*" \
    "GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT=1"
}

# A ready-to-enable NVIDIA unit on the given OS.
nvidia_ready() {
  set_os "$1"
  nvidia_driver installed
  nvidia_configs backup
  egpu_appears nvidia
}

@test "cable not locked: exit 1" {
  set_connected 0
  run_plugin_script egpu-enable nvidia
  assert_failure 1
  assert_equal "$(grep -c 'XG Mobile not locked' <<< "$LOG")" 1
  refute_called "systemctl stop sddm"
}

@test "egpu_connected missing: treated as not locked, exit 1" {
  rm "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_connected"
  run_plugin_script egpu-enable amd
  assert_failure 1
}

@test "steamos + nvidia + driver missing: exit 2" {
  set_os steamos
  run_plugin_script egpu-enable nvidia
  assert_failure 2
  refute_called "steamos-readonly"
}

@test "cachyos + nvidia + driver missing: exit 2" {
  set_os cachyos
  run_plugin_script egpu-enable nvidia
  assert_failure 2
}

@test "bazzite-nvidia + driver missing: no driver check, card wait instead" {
  set_os bazzite-nvidia
  run_plugin_script egpu-enable nvidia
  assert_failure 5
  refute_called "modinfo"
}

@test "vulkan configs only in the old v0.2.0 location: exit 3" {
  nvidia_driver installed
  nvidia_configs old
  run_plugin_script egpu-enable nvidia
  assert_failure 3
}

@test "vulkan configs missing: exit 4" {
  nvidia_driver installed
  nvidia_configs missing
  run_plugin_script egpu-enable nvidia
  assert_failure 4
}

@test "vulkan configs already in place (not de-fanged): passes the config check" {
  nvidia_driver installed
  echo '{}' > "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json"
  egpu_appears nvidia
  run_plugin_script egpu-enable nvidia
  assert_success
}

@test "card never appears: exit 5 after 15 loop iterations" {
  egpu_appears never
  run_plugin_script egpu-enable amd
  assert_failure 5
  [[ "$LOG" == *"Waiting for eGPU card... (14)"* ]]
  [[ "$LOG" != *"Waiting for eGPU card... (15)"* ]]
  assert_equal "$(calls_matching 'sleep 1' | wc -l)" 15
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 1
}

@test "steamos + nvidia + lspci empty: exit 6" {
  nvidia_ready steamos
  set_lspci empty
  run_plugin_script egpu-enable nvidia
  assert_failure 6
  refute_called "modprobe nvidia_drm modeset=1 fbdev=1"
}

@test "happy path steamos/nvidia: environment, services, modules, plasma env, log symlink" {
  nvidia_ready steamos
  local before
  before="$(cat "$ROOT/etc/environment")"

  run_plugin_script egpu-enable nvidia
  assert_success

  # /etc/environment gains exactly the 5 NVIDIA vars
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"$'\n'"$(NVIDIA_ENV_LINES)"

  # systemctl set-environment for each, system-wide
  local line
  while IFS= read -r line; do
    assert_called "systemctl set-environment $line"
  done < <(NVIDIA_ENV_LINES)
  assert_called "systemctl --user set-environment MESA_VK_DEVICE_SELECT=10de:2717"
  assert_called "systemctl --user set-environment WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"

  assert_called_before "systemctl stop sddm" "systemctl start sddm"
  assert_called "modprobe nvidia_drm modeset=1 fbdev=1"
  assert_called "setfacl -m u:deck:rw $ROOT/dev/dri/card1"
  assert_equal "$(cat "$ROOT/etc/modprobe.d/nvidia-egpu.conf")" "options nvidia_drm modeset=1 fbdev=1"

  # NVIDIA configs re-fanged out of the backup
  assert [ -f "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  assert [ -f "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ -f "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json" ]

  local plasma="$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  assert [ -x "$plasma" ]
  run cat "$plasma"
  assert_line "export KWIN_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
  assert_line "export GBM_BACKEND=nvidia-drm"

  assert_equal "$(readlink "$LOG_DIR/xgmobile_manager_enable_latest.log")" "$LOG_DIR/xgmobile_manager_enable_nvidia.log"
  refute_called "systemctl stop supergfxd.service"
}

@test "happy path cachyos/nvidia: same injection as steamos" {
  nvidia_ready cachyos
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_called "systemctl set-environment MESA_VK_DEVICE_SELECT=10de:2717"
  assert_called "modprobe nvidia_drm modeset=1 fbdev=1"
}

@test "happy path steamos/amd: only WLR_DRM_DEVICES is set" {
  egpu_appears amd
  local before
  before="$(cat "$ROOT/etc/environment")"

  run_plugin_script egpu-enable amd
  assert_success

  assert_equal "$(cat "$ROOT/etc/environment")" "$before"$'\n'"WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
  assert_equal "$(grep -c '^systemctl .*set-environment' "$SHIM_LOG")" 2
  assert_called "systemctl set-environment WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
  assert_called "systemctl --user set-environment WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
  refute_called "modprobe"
  refute_called "lspci"
  assert [ ! -e "$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert_called_before "systemctl stop sddm" "systemctl start sddm"
  assert_equal "$(readlink "$LOG_DIR/xgmobile_manager_enable_latest.log")" "$LOG_DIR/xgmobile_manager_enable_amd.log"
}

@test "bazzite + nvidia: modprobe sequence runs, /etc/environment untouched" {
  set_os bazzite-nvidia
  egpu_appears nvidia
  local before
  before="$(cat "$ROOT/etc/environment")"

  run_plugin_script egpu-enable nvidia
  assert_success

  assert_called_before "modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia" "modprobe nvidia_drm modeset=1 fbdev=1"
  assert_called "modprobe nvidia_modeset nvidia_uvm nvidia"
  assert_called "systemctl start nvidia-persistenced nvidia-powerd"
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"
  refute_called "systemctl set-environment"
  refute_called "steamos-readonly"
  assert [ ! -e "$ROOT/etc/modprobe.d/nvidia-egpu.conf" ]
}

@test "active supergfxd is stopped before the switch" {
  egpu_appears amd
  supergfxd_active
  run_plugin_script egpu-enable amd
  assert_success
  assert_called_before "systemctl stop supergfxd.service" "systemctl stop sddm"
}

@test "Ally + supergfxctl installed: supergfxd is disabled" {
  set_product "ROG Ally RC71L_RC71L"
  egpu_appears amd
  enable_supergfxctl
  run_plugin_script egpu-enable amd
  assert_success
  assert_called "systemctl disable supergfxd.service"
}

@test "Ally without supergfxctl: supergfxd is left alone" {
  set_product "ROG Ally RC71L_RC71L"
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  refute_called "systemctl disable supergfxd.service"
}

@test "Flow laptop + supergfxctl installed: supergfxd is left active" {
  set_product "ROG Flow Z13 GZ301ZE"
  egpu_appears amd
  enable_supergfxctl
  run_plugin_script egpu-enable amd
  assert_success
  refute_called "systemctl disable supergfxd.service"
}
