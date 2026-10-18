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

# No eGPU variable is left in either systemd manager (shims/systemctl tracks them), and the log
# says so.
assert_managers_clean() {
  local scope
  for scope in system user; do
    run grep -E '^(MESA_VK_DEVICE_SELECT|VK_ICD_FILENAMES|WLR_DRM_DEVICES|VK_LOADER_LAYERS_DISABLE|GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT|KWIN_DRM_DEVICES|GBM_BACKEND|__GLX_VENDOR_LIBRARY_NAME)=' "$SHIM_STATE/env/$scope"
    assert_output ""
    [[ "$LOG" == *"eGPU variables left in $scope manager: none"* ]] || fail "no 'left in $scope manager: none' line in the eject log"
  done
  [[ "$LOG" == *"eGPU variables left in /etc/environment: none"* ]] || fail "no /etc/environment line in the eject log"
}

# All five variables egpu-enable can inject are unset in both systemd managers, whatever subset
# enable actually set (a user manager can hold values from an older plugin version).
assert_full_unset() {
  local var
  for var in MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT; do
    assert_called "systemctl unset-environment $var"
    assert_called "systemctl --user unset-environment $var"
  done
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
  assert_full_unset
  assert_managers_clean
  assert_called "modprobe -r nvidia"
  refute_called "systemctl disable xgmobile-boot-sync.service"
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped from the PCIe bus."* ]]
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
  assert_full_unset
  assert_managers_clean
  refute_called "modprobe"
  refute_called "systemctl disable xgmobile-boot-sync.service"
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped from the PCIe bus."* ]]
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

# Pass 2, CachyOS: the persistent Plasma desktop had imported the eGPU variables into the user
# manager (and the Plasma env file's three), and gamescope started with them after the eject.
@test "cachyos: eGPU variables a Plasma session imported into the user manager are unset, before/after logged" {
  os_like_hardware cachyos
  nvidia_driver installed
  egpu_present nvidia
  record_egpu_pci
  manager_env user "LANG=en_US.UTF-8" "MESA_VK_DEVICE_SELECT=10de:2717" "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" \
    "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" "VK_LOADER_LAYERS_DISABLE=*" "GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT=1" \
    "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" "GBM_BACKEND=nvidia-drm" "__GLX_VENDOR_LIBRARY_NAME=nvidia"
  echo "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json" >> "$ROOT/etc/environment"
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_equal "$(manager_env_of user)" "LANG=en_US.UTF-8"
  assert_managers_clean
  [[ "$LOG" == *"eGPU variables found in user manager: MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT KWIN_DRM_DEVICES GBM_BACKEND __GLX_VENDOR_LIBRARY_NAME"* ]]
  [[ "$LOG" == *"eGPU variables found in system manager: none"* ]]
}

@test "eGPU PCI device drops: success logged without the 15 s wait, sddm restarted, egpu_enable cleared" {
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped from the PCIe bus. eGPU safely detached."* ]]
  [[ "$LOG" != *"WARNING"* ]]
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 1
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_equal "$(readlink "$LOG_DIR/eject_latest.log")" "$LOG_DIR/eject_amd.log"
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

@test "eGPU PCI device doesn't drop: WARNING logged, still exit 0 and sddm restarted" {
  egpu_present amd
  egpu_drops no
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"WARNING: Hardware did not seem to drop from the PCIe bus."* ]]
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 15
  assert_called "systemctl start sddm.service"
}

@test "bazzite/nvidia: modules unloaded, /etc/environment and configs untouched" {
  set_os bazzite-nvidia
  egpu_present nvidia
  gpu_holders 100
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_success
  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  assert_called "modprobe -r nvidia_drm"
  assert_fuser_kill_before_unload
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

# Line number of the first shim-log line starting with the given text (empty if none).
first_line() { grep -nF -- "$1" "$SHIM_LOG" | head -n 1 | cut -d: -f1; }

# Every `fuser -k...` comes before the first `modprobe -r nvidia_drm`.
assert_fuser_kill_before_unload() {
  local kill unload
  kill=$(grep -n '^fuser -k' "$SHIM_LOG" | tail -n 1 | cut -d: -f1)
  unload=$(grep -nx 'modprobe -r nvidia_drm' "$SHIM_LOG" | head -n 1 | cut -d: -f1)
  [ -n "$kill" ] || fail "fuser -k was never called"
  [ -n "$unload" ] || fail "modprobe -r nvidia_drm was never called"
  [ "$kill" -lt "$unload" ] || fail "fuser -k (line $kill) must come before modprobe -r nvidia_drm (line $unload)"
}

# assert_fuser_only_egpu_nodes <eGPU card> <eGPU render> <iGPU card> <iGPU render> [<eGPU fb>
# <iGPU fb>]: every fuser call got the eGPU's nodes and none of the iGPU's (fb1/fb0 by default).
assert_fuser_only_egpu_nodes() {
  local line efb="${5:-fb1}" ifb="${6:-fb0}"
  [ -n "$(calls_matching 'fuser ')" ] || fail "fuser was never called"
  while IFS= read -r line; do
    line="$line "
    [[ "$line" == *"/dev/dri/$1 "* && "$line" == *"/dev/dri/$2 "* ]] || fail "eGPU nodes $1/$2 missing from: $line"
    [[ "$line" == *"/dev/$efb "* ]] || fail "eGPU framebuffer $efb missing from: $line"
    [[ "$line" != *"/dev/dri/$3 "* ]] || fail "iGPU node $3 passed to fuser: $line"
    [[ "$line" != *"/dev/dri/$4 "* ]] || fail "iGPU node $4 passed to fuser: $line"
    [[ "$line" != *"/dev/$ifb "* ]] || fail "iGPU framebuffer $ifb passed to fuser: $line"
  done < <(calls_matching 'fuser ')
}

# The NVIDIA power services were stopped and are running again.
assert_nvidia_services_restored() {
  assert_called_before "systemctl stop nvidia-powerd nvidia-persistenced" "systemctl start nvidia-persistenced nvidia-powerd"
}

# The eject was cancelled before anything was undone: XG Mobile still on, environment intact,
# display manager restarted, exit 7.
assert_cancelled() {
  assert_failure 7
  [[ "$LOG" == *"ERROR: The eGPU is still in use. Eject cancelled"* ]]
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 1
  assert_equal "$(cat "$ROOT/sys/bus/pci/rescan")" ""
  cmp "$BATS_TEST_TMPDIR/environment.before" "$ROOT/etc/environment"
  refute_called "systemctl unset-environment"
  assert_called_before "systemctl stop $1" "systemctl start $1"
  # The plugin shows the cancel after the restart from this marker.
  [[ "$(cat "$DATA_DIR/last_eject_cancelled")" =~ ^[0-9]+$ ]] || fail "cancel marker missing or not a timestamp"
  [[ "$LOG" == *"--- GPU diagnostics ---"* ]]
}

@test "release order: DM stopped, wait, SIGTERM, wait, SIGKILL, then the NVIDIA modules unloaded" {
  set_os cachyos
  no_steamos_readonly
  record_egpu_pci
  egpu_present nvidia
  gpu_holders ignore-term
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called_before "systemctl stop plasmalogin.service" "modprobe -r nvidia_drm"
  assert_called_before "systemctl stop nvidia-powerd nvidia-persistenced" "modprobe -r nvidia_drm"
  local term kill unload
  term=$(first_line "fuser -k -TERM ")
  kill=$(first_line "fuser -k -KILL ")
  unload=$(first_line "modprobe -r nvidia_drm")
  [ -n "$term" ] && [ -n "$kill" ] || fail "expected fuser -k -TERM and fuser -k -KILL"
  [ "$term" -lt "$kill" ] || fail "SIGTERM (line $term) must come before SIGKILL (line $kill)"
  assert_fuser_kill_before_unload
  # 10 s graceful wait, then 5 s after SIGTERM, before SIGKILL.
  assert_equal "$(head -n "$term" "$SHIM_LOG" | grep -c '^sleep 1$')" 10
  assert_equal "$(head -n "$kill" "$SHIM_LOG" | grep -c '^sleep 1$')" 15
  # The holder list is logged before each kill.
  [[ "$LOG" == *"Processes still using the eGPU:"*"gamescope-wl"*"Sending SIGTERM"*"Sending SIGKILL"* ]]
  assert_fuser_only_egpu_nodes card1 renderD129 card0 renderD128
  assert_equal "$(calls_matching 'fuser -k -KILL' | grep -c 'nvidiactl')" 1
  assert [ ! -e "$ROOT/sys/module/nvidia_drm" ]
}

@test "holders exit on SIGTERM: no SIGKILL" {
  egpu_present nvidia
  gpu_holders 100
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called_before "fuser -k -TERM $ROOT/dev/dri/card1 $ROOT/dev/dri/renderD129 $ROOT/dev/fb1 $ROOT/dev/nvidia-modeset $ROOT/dev/nvidia0 $ROOT/dev/nvidiactl" "modprobe -r nvidia_drm"
  refute_called "fuser -k -KILL"
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
}

@test "nothing holds the eGPU: no signals sent" {
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "fuser -k"
  assert_called "modprobe -r nvidia_drm"
}

@test "processes exit on their own during the wait: no extra delay after they're gone" {
  egpu_present nvidia
  gpu_holders 3
  run_plugin_script egpu-eject nvidia
  assert_success
  # 3 waits for the holders, 1 for the PCI device to drop.
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 4
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped"* ]]
}

@test "nvidia_drm stays loaded but no process uses the eGPU: WARNING, diagnostics, powered off anyway" {
  set_os cachyos
  no_steamos_readonly
  egpu_present nvidia
  # As captured on CachyOS: the DRM fbdev client holds nvidia_drm (refcnt 50, no holders).
  module_stuck nvidia_drm
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"WARNING: NVIDIA driver still loaded (in-kernel framebuffer reference); no processes use the eGPU, powering it off as before."* ]]
  # Diagnostics: /proc/fb, consoles, fb -> device, module params, refcnt, lsmod.
  [[ "$LOG" == *"1 nvidia-drmdrmfb"* ]]
  [[ "$LOG" == *"vtcon0: (S) dummy device (bind 1)"* ]]
  [[ "$LOG" == *"fb1 -> 0000:01:00.0"* ]]
  [[ "$LOG" == *"fb0 -> 0000:08:00.0"* ]]
  [[ "$LOG" == *"nvidia_drm modeset=Y fbdev=Y"* ]]
  [[ "$LOG" == *"nvidia_drm refcnt before the release: 50, now: 50"* ]]
  [ -n "$(calls_matching lsmod)" ] || fail "lsmod not called for the diagnostics"
  [[ "$LOG" != *"nvidia_drm is held by modules"* ]]
  # The modules under nvidia_drm can't go either, so they're left alone.
  [[ "$LOG" == *"nvidia_drm couldn't be unloaded; leaving the other NVIDIA modules loaded."* ]]
  refute_called "modprobe -r nvidia_uvm"
  refute_called "modprobe -r nvidia_modeset"
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
  assert [ ! -e "$DATA_DIR/last_eject_cancelled" ]
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped"* ]]
}

@test "nvidia_drm held by other modules: logged, powered off anyway" {
  egpu_present nvidia
  module_stuck nvidia_drm
  mkdir -p "$ROOT/sys/module/nvidia_drm/holders/some_module"
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"nvidia_drm is held by modules (not processes): some_module"* ]]
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
}

@test "safety stop: process still holds the eGPU after SIGKILL, cancelled with exit 7" {
  set_os cachyos
  no_steamos_readonly
  egpu_present nvidia
  gpu_holders unkillable
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled plasmalogin.service
  assert_called "fuser -k -KILL $ROOT/dev/dri/card1 $ROOT/dev/dri/renderD129 $ROOT/dev/fb1 $ROOT/dev/nvidia-modeset $ROOT/dev/nvidia0 $ROOT/dev/nvidiactl"
  [[ "$LOG" == *"Processes still using the eGPU:"*"gamescope-wl"* ]]
  assert [ -e "$ROOT/sys/class/drm/card1" ]
  [[ "$LOG" != *"Success!"* ]]
  assert_nvidia_services_restored
  refute_called "systemctl enable nvidia-powerd nvidia-persistenced"
}

@test "safety stop: nvidia_drm busy and a process still holding: nothing past nvidia_drm unloaded" {
  egpu_present nvidia
  gpu_holders unkillable
  module_stuck nvidia_drm
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
  assert_called "modprobe -r nvidia_drm"
  refute_called "modprobe -r nvidia_uvm"
  refute_called "modprobe -r nvidia_modeset"
  refute_called "modprobe -r nvidia"
  assert [ -e "$ROOT/sys/module/nvidia" ]
  assert_nvidia_services_restored
}

@test "safety stop: AMD eGPU still held after the kill, holders logged, exit 7" {
  egpu_present amd
  gpu_holders unkillable
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject amd
  assert_cancelled sddm.service
  [[ "$LOG" == *"Processes still using the eGPU:"* ]]
  [[ "$LOG" == *"card1:      xgmtest    4242 F.... gamescope-wl"* ]]
  refute_called "modprobe"
  refute_called "systemctl start nvidia-persistenced nvidia-powerd"
}

@test "safety stop on bazzite: same cancel, NVIDIA services re-enabled and started" {
  set_os bazzite-nvidia
  no_steamos_readonly
  egpu_present nvidia
  gpu_holders unkillable
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
  assert_called_before "systemctl disable nvidia-powerd nvidia-persistenced" "systemctl enable nvidia-powerd nvidia-persistenced"
  assert_nvidia_services_restored
}

@test "a later successful eject clears an old cancel marker and saved result" {
  date +%s > "$DATA_DIR/last_eject_cancelled"
  echo '{"timestamp": 0, "result": {}}' > "$DATA_DIR/last_result.json"
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert [ ! -e "$DATA_DIR/last_eject_cancelled" ]
  assert [ ! -e "$DATA_DIR/last_result.json" ]
}

@test "safety stop with supergfxd running (Flow laptop): supergfxd started again" {
  set_product "ROG Flow X13 GV301QH"
  supergfxd_active
  egpu_present nvidia
  gpu_holders unkillable
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
  assert_called_before "systemctl stop supergfxd.service" "systemctl start supergfxd.service"
}

@test "safety stop without supergfxd: supergfxd not started" {
  egpu_present nvidia
  gpu_holders unkillable
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
  refute_called "systemctl start supergfxd.service"
}

@test "egpu_enable already 0: no release or wait, environment still sanitized, DM restarted" {
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"XG Mobile is already off. Skipping the GPU release."* ]]
  refute_called "fuser"
  refute_called "modprobe"
  refute_called "sleep"
  run grep -c WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output 0
  assert_full_unset
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
}

@test "amd, active but no eGPU found: release and wait skipped, egpu_enable still cleared" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"No eGPU found. Skipping the GPU release."* ]]
  refute_called "fuser"
  refute_called "sleep"
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
}

@test "nvidia, active but no eGPU PCI device: /dev/nvidia* still released and the modules unloaded" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  touch "$ROOT/dev/nvidiactl" "$ROOT/dev/nvidia0"
  mkdir -p "$ROOT/sys/module/nvidia_drm" "$ROOT/sys/module/nvidia"
  gpu_holders 100
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"No eGPU PCI device found. Releasing the NVIDIA device nodes and modules anyway."* ]]
  assert_called "fuser -k -TERM $ROOT/dev/nvidia0 $ROOT/dev/nvidiactl"
  assert_fuser_kill_before_unload
  assert_called "modprobe -r nvidia"
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
}

@test "nvidia, no eGPU PCI device, /dev/nvidia* still held: device-scoped stop, exit 7" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  touch "$ROOT/dev/nvidiactl" "$ROOT/dev/nvidia0"
  gpu_holders unkillable
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
}

@test "AMD eGPU: identified by boot_vga even though both cards are 0x1002" {
  egpu_present amd
  assert_equal "$(cat "$ROOT/sys/class/drm/card1/device/vendor")" "0x1002"
  # A connector entry has no boot_vga either; it must not count as a GPU.
  mkdir -p "$ROOT/sys/class/drm/card0-eDP-1/device"
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129 fb1)"* ]]
  assert_equal "$(grep -c '^eGPU: ' <<< "$LOG")" 1
  assert_fuser_only_egpu_nodes card1 renderD129 card0 renderD128
}

# Card numbers aren't stable across boots: the captured Ally had the eGPU as card0 with
# renderD129, and the iGPU's renderD128 held by steamwebhelper. The framebuffers swap with the
# cards. eject_with_numbering <eGPU card> <eGPU render> <iGPU card> <iGPU render> <record|no-record>
eject_with_numbering() {
  local efb=fb1 ifb=fb0
  [ "$1" = "card0" ] && { efb=fb0; ifb=fb1; }
  gpu_numbering "$3" "$4" "$1" "$2" "$ifb" "$efb"
  [ "$5" = "record" ] && record_egpu_pci
  egpu_present nvidia
  gpu_holders 100
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 ($1 $2 $efb)"* ]] || fail "eGPU nodes not resolved as $1 $2 $efb: $LOG"
  assert_fuser_only_egpu_nodes "$1" "$2" "$3" "$4" "$efb" "$ifb"
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped"* ]]
  assert [ -e "$ROOT/dev/dri/$3" ]
  assert [ -e "$ROOT/dev/dri/$4" ]
}

@test "numbering as captured (eGPU card0 + renderD129), recorded address: only the eGPU's nodes" {
  eject_with_numbering card0 renderD129 card1 renderD128 record
}

@test "numbering as captured (eGPU card0 + renderD129), no record: boot_vga fallback" {
  eject_with_numbering card0 renderD129 card1 renderD128 no-record
}

@test "eGPU card1 + renderD128, recorded address: only the eGPU's nodes" {
  eject_with_numbering card1 renderD128 card0 renderD129 record
}

@test "eGPU card1 + renderD128, no record: boot_vga fallback" {
  eject_with_numbering card1 renderD128 card0 renderD129 no-record
}

@test "recorded PCI address wins over boot_vga" {
  egpu_present nvidia
  # A firmware that flags the eGPU as boot VGA: the fallback can't find it, the record can.
  echo 1 > "$ROOT/sys/class/drm/card1/device/boot_vga"
  record_egpu_pci
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129 fb1)"* ]]
  assert_called "modprobe -r nvidia_drm"
}

@test "amd, no record and no non-boot-VGA device: no eGPU found, release skipped" {
  egpu_present amd
  echo 1 > "$ROOT/sys/class/drm/card1/device/boot_vga"
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"No eGPU found. Skipping the GPU release."* ]]
  refute_called "fuser"
}

@test "recorded address that isn't a display controller: boot_vga fallback" {
  # Something else (a USB controller, class 0x0c0330) now sits at the recorded address.
  local dev="$ROOT/sys/devices/pci0000:00/0000:00:08.3/0000:09:00.0"
  mkdir -p "$dev"
  echo 0x0c0330 > "$dev/class"
  ln -s "$dev" "$ROOT/sys/bus/pci/devices/0000:09:00.0"
  record_egpu_pci 0000:09:00.0
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129 fb1)"* ]]
  [[ "$LOG" != *"eGPU: 0000:09:00.0"* ]]
}

@test "recorded address that no longer exists: boot_vga fallback" {
  record_egpu_pci 0000:05:00.0
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129 fb1)"* ]]
}

@test "malformed record is ignored: boot_vga fallback" {
  record_egpu_pci "../../../../etc"
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129 fb1)"* ]]
}

@test "eject never disables the boot safety net" {
  sync_service_installed
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "systemctl disable xgmobile-boot-sync.service"
  assert [ -e "$SHIM_STATE/enabled/xgmobile-boot-sync.service" ]
}

@test "primary user: Steam not running, first regular user with a home dir" {
  steam_not_running
  mkdir -p "$ROOT/home/nohome/.config/plasma-workspace/env"
  touch "$ROOT/home/nohome/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert [ ! -e "$ROOT/home/nohome/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
}

@test "primary user: Steam running as deck stays deck" {
  steam_user deck
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert_called "id -u deck"
  assert_called "setpriv --reuid=64999 --regid=64999 --init-groups env XDG_RUNTIME_DIR=$ROOT/run/user/64999 systemctl --user unset-environment WLR_DRM_DEVICES"
  assert_called "sudo -u deck XDG_RUNTIME_DIR=/run/user/64999 systemctl --user daemon-reload"
}

@test "egpu_enable write fails: friendly line, no shell error in the log, the drop wait decides" {
  egpu_present amd
  record_egpu_pci
  chmod 444 "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"asus-nb-wmi reported an error switching the eGPU off (usually harmless); checking that the eGPU dropped..."* ]]
  [[ "$LOG" == *"WARNING: Hardware did not seem to drop from the PCIe bus."* ]]
  [[ "$LOG" != *"write error"* && "$LOG" != *"Permission denied"* ]]
}

# Step 0, exp 2: with the display manager stopped the user manager can already be gone, and the
# user daemon-reload only logged "Failed to connect to user scope bus via local transport".
@test "no user bus: no user daemon-reload, the system one still runs" {
  set_os steamos
  egpu_present amd
  rm -f "$ROOT/run/user/64999/bus"
  run_plugin_script egpu-eject amd
  assert_success
  assert_called "systemctl daemon-reload"
  refute_called "systemctl --user daemon-reload"
  refute_called "sudo -u xgmtest XDG_RUNTIME_DIR=/run/user/64999 systemctl --user daemon-reload"
  [[ "$LOG" == *"user manager not running; no reload needed"* ]]
}

@test "user bus present: the user daemon-reload still runs" {
  set_os cachyos
  no_steamos_readonly
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  assert_called "sudo -u xgmtest XDG_RUNTIME_DIR=/run/user/64999 systemctl --user daemon-reload"
  [[ "$LOG" != *"no reload needed"* ]]
}

# Pass 4: a user manager that started with the eGPU variables (a boot with the XG Mobile active)
# keeps them in its initial environment; unset-environment can't remove them. If the display
# manager comes back within logind's UserStopDelay, or an SSH login is open, that manager survives
# the eject and Game Mode starts with them, so egpu-eject stops it (xgm_restart_dirty_user_manager).
# The variables as the S3 capture showed them (show-environment sorts and quotes).
S3_ENV=(
  "GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT=1"
  "MESA_VK_DEVICE_SELECT=10de:2717"
  "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json"
  "VK_LOADER_LAYERS_DISABLE=\$'*'"
  "WLR_DRM_DEVICES=/dev/dri/card0:/dev/dri/card1"
)
S3_NAMES="GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES VK_LOADER_LAYERS_DISABLE WLR_DRM_DEVICES"
RESTART_LINE="eGPU variables can't be removed from the running user manager (it started with them): $S3_NAMES; restarting it so the next login starts clean"
STOP_MANAGER="systemctl stop --no-block user@64999.service"

# The line number of the first eject log line containing the text, or 0.
log_line() { grep -Fn -- "$1" "$LOG_DIR/eject_$2.log" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
# The line number of the first (shim_first) or last (shim_last) shim log line equal to the text, or 0.
shim_first() { grep -Fxn -- "$1" "$SHIM_LOG" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
shim_last() { grep -Fxn -- "$1" "$SHIM_LOG" | tail -n 1 | cut -d: -f1 | grep . || echo 0; }
# How many shim log lines equal the text, between lines <from> and <to>.
count_between() { sed -n "$2,$3p" "$SHIM_LOG" | grep -cFx -- "$1" || true; }

# assert_ascending <label> <n>...: every n is > 0 and greater than the one before.
assert_ascending() {
  local label="$1" prev=0 n
  shift
  for n in "$@"; do
    [ "$n" -gt "$prev" ] || fail "$label: expected ascending line numbers > 0, got: $*"
    prev=$n
  done
}

# An NVIDIA eGPU enabled at boot: /etc/environment had the variables when the user manager started.
dirty_manager_eject_setup() {
  os_like_hardware "$1"
  nvidia_driver installed
  egpu_present nvidia
  record_egpu_pci
  user_initial_env "${S3_ENV[@]}"
  export XGM_WAIT_POLL=0.01
}

@test "pass 4 S3 (SteamOS Game Mode eject, the manager survives): stopped, the DM started once it's gone" {
  dirty_manager_eject_setup steamos
  # The capture: the old login session closed, only the Class=manager session was left.
  timeline sessions "0 2:manager:active"
  manager_after stop "0 deactivating" "3 inactive"
  run_plugin_script egpu-eject nvidia
  assert_success

  assert_ascending "eject log" \
    "$(log_line "eGPU variables left in user manager: $S3_NAMES" nvidia)" \
    "$(log_line "$RESTART_LINE" nvidia)" \
    "$(log_line "old user manager stopped after 0.03s" nvidia)" \
    "$(log_line "Starting sddm.service..." nvidia)"
  local stop start
  stop=$(shim_first "$STOP_MANAGER")
  start=$(shim_first "systemctl start sddm.service")
  assert_ascending "shim log" "$(shim_last "setpriv --reuid=64999 --regid=64999 --init-groups env XDG_RUNTIME_DIR=$ROOT/run/user/64999 systemctl --user show-environment")" \
    "$stop" "$(shim_first "systemctl daemon-reload")" "$start"
  # It waited the 3 polls until the manager was inactive before going on.
  assert_equal "$(count_between "sleep 0.01" "$stop" "$start")" 3
  assert_equal "$(grep -cFx "$STOP_MANAGER" "$SHIM_LOG")" 1
  refute_called "systemctl start user@64999.service"
  refute_called "systemctl kill"
  refute_called "systemctl --user kill"
}

@test "pass 4 CachyOS, Game Mode eject with an SSH login open: the manager is stopped anyway" {
  dirty_manager_eject_setup cachyos
  # Session 5 is the SSH login (Class=user); it keeps the manager alive past UserStopDelay.
  timeline sessions "0 1:user:active 2:manager:active 5:user:active"
  manager_after stop "0 deactivating" "1 inactive"
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called_before "$STOP_MANAGER" "systemctl start plasmalogin.service"
  [[ "$LOG" == *"$RESTART_LINE"* ]]
  [[ "$LOG" == *"old user manager stopped after 0.01s"* ]]
  refute_called "loginctl"
}

@test "pass 4 C3 (CachyOS desktop Eject icon, a fast eject): stopped before the DM start, the cleanup then finds a clean new manager" {
  dirty_manager_eject_setup cachyos
  timeline sessions "0 1:user:active 2:manager:active"
  # The eject took 8 s: the old manager is gone at once, and the DM's new login brings up a new one.
  manager_after stop "0 inactive" "1 active:new"
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called_before "$STOP_MANAGER" "systemctl start plasmalogin.service"
  [[ "$LOG" == *"old user manager stopped after 0.00s"* ]]

  # The desktop Eject link's cleanup (main.py) with the sessions from before the eject.
  timeline sessions "0 3:user:active 4:manager:active"
  assert_equal "$(tl_manager_state) $(tl_manager_id)" "active new"
  run_script clean-session-env xgmtest "$LOG_DIR" "1 2"
  assert_success
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "user session ready after 0.00s (session 3)"
  assert_line "eGPU variables found in user manager: none"
  assert_line "eGPU variables left in user manager: none"
}

@test "a clean manager (only set-environment variables, which unset removes): not stopped" {
  os_like_hardware steamos
  nvidia_driver installed
  egpu_present nvidia
  record_egpu_pci
  manager_env user "${S3_ENV[@]}"
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU variables found in user manager: $S3_NAMES"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
  refute_called "systemctl stop --no-block user@"
  refute_called "systemctl stop user@"
  [[ "$LOG" != *"restarting it"* && "$LOG" != *"old user manager"* ]]
}

@test "the user manager isn't running: nothing to stop" {
  dirty_manager_eject_setup steamos
  timeline manager "0 inactive"
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "systemctl stop --no-block user@"
  [[ "$LOG" != *"restarting it"* && "$LOG" != *"old user manager"* ]]
  assert_called "systemctl start sddm.service"
}

@test "the user manager is active but its environment can't be read: stopped" {
  dirty_manager_eject_setup steamos
  user_manager_down
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called_before "$STOP_MANAGER" "systemctl start sddm.service"
  [[ "$LOG" == *"eGPU variables can't be removed from the running user manager (it started with them): unknown (couldn't read it: Failed to connect to bus: No such file or directory); restarting it so the next login starts clean"* ]]
  [[ "$LOG" == *"old user manager stopped after 0.00s"* ]]
}

@test "the stopped manager hangs: its stuck units after XGM_HUNG_AFTER, then the manager XGM_HUNG_AFTER later, once each" {
  dirty_manager_eject_setup steamos
  export XGM_HUNG_AFTER=0.05 XGM_RESTART_CAP=1
  manager_after stop "0 deactivating"
  stuck_unit xdg-document-portal.service
  doc_mounted
  run_plugin_script egpu-eject nvidia
  assert_success

  local stop fuse unit_kill manager_kill start
  stop=$(shim_first "$STOP_MANAGER")
  fuse=$(shim_first "fusermount3 -uz $ROOT/run/user/64999/doc")
  unit_kill=$(shim_first "systemctl --user kill -s KILL -- xdg-document-portal.service")
  manager_kill=$(shim_first "systemctl kill -s KILL user@64999.service")
  start=$(shim_first "systemctl start sddm.service")
  assert_ascending "stop, fusermount3, unit kill, manager kill, DM start" "$stop" "$fuse" "$unit_kill" "$manager_kill" "$start"
  assert_equal "$(count_between "sleep 0.01" "$stop" "$fuse")" 5
  assert_equal "$(count_between "sleep 0.01" "$unit_kill" "$manager_kill")" 5
  assert_equal "$(grep -cFx "systemctl kill -s KILL user@64999.service" "$SHIM_LOG")" 1
  assert_equal "$(grep -c "^systemctl --user kill" "$SHIM_LOG")" 1
  run cat "$LOG_DIR/eject_nvidia.log"
  assert_line "old user manager still stopping after 0.05s; ending its stuck units"
  assert_line "killed stuck unit: xdg-document-portal.service"
  assert_line "old user manager still stopping; killing it"
  assert_line --regexp '^old user manager stopped after 0\.1[0-9]s$'
}

@test "the stopped manager is replaced between list-units and the unit kills: nothing killed" {
  dirty_manager_eject_setup steamos
  export XGM_HUNG_AFTER=0.05 XGM_RESTART_CAP=1
  manager_after stop "0 deactivating"
  manager_after list-units "0 active:new"
  stuck_unit xdg-document-portal.service
  stuck_unit app-steam@autostart.service
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_called "systemctl --user list-units --state=deactivating --no-legend --plain"
  refute_called "systemctl --user kill"
  refute_called "systemctl kill"
  run cat "$LOG_DIR/eject_nvidia.log"
  assert_line "old user manager gone; not killing xdg-document-portal.service"
  assert_line "old user manager stopped after 0.06s"
}

@test "the stopped manager is replaced right before the step-2 kill: the new one isn't killed" {
  dirty_manager_eject_setup steamos
  export XGM_HUNG_AFTER=0.05 XGM_RESTART_CAP=1
  manager_after stop "0 deactivating"
  # Shows of user@64999: 1 in the cleanup, 2 before the stop, 3-13 the polls of ticks 0-10 (step 1
  # at tick 5 has no units, so no recheck); the 14th is step 2's recheck, which finds a new manager.
  manager_after show:13 "0 deactivating:new"
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "systemctl kill"
  run cat "$LOG_DIR/eject_nvidia.log"
  assert_line "old user manager still stopping after 0.05s; ending its stuck units"
  assert_line "old user manager gone; not killing user@64999.service"
  refute_line "old user manager still stopping; killing it"
  assert_line "old user manager stopped after 0.11s"
}

@test "the stopped manager outlives the kill: gives up at XGM_RESTART_CAP, the DM still starts" {
  dirty_manager_eject_setup steamos
  export XGM_HUNG_AFTER=0.05 XGM_RESTART_CAP=0.2
  manager_after stop "0 deactivating"
  manager_after kill "0 deactivating"
  run_plugin_script egpu-eject nvidia
  assert_success
  assert_equal "$(grep -cFx "systemctl kill -s KILL user@64999.service" "$SHIM_LOG")" 1
  assert_equal "$(count_between "sleep 0.01" "$(shim_first "$STOP_MANAGER")" "$(shim_first "systemctl start sddm.service")")" 20
  assert_ascending "eject log" \
    "$(log_line "user manager still running after 0.2s; continuing (a reboot clears the eGPU variables)" nvidia)" \
    "$(log_line "Starting sddm.service..." nvidia)"
  [[ "$LOG" != *"old user manager stopped"* ]]
}

@test "bazzite: the user manager is never stopped" {
  set_os bazzite-nvidia
  no_steamos_readonly
  egpu_present nvidia
  record_egpu_pci
  user_initial_env "${S3_ENV[@]}"
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "systemctl stop --no-block user@"
  [[ "$LOG" != *"restarting it"* ]]
}

@test "safety stop (exit 7): the eGPU stays active, so the user manager isn't stopped" {
  dirty_manager_eject_setup cachyos
  gpu_holders unkillable
  run_plugin_script egpu-eject nvidia
  assert_equal "$status" 7
  refute_called "systemctl stop --no-block user@"
  [[ "$LOG" != *"restarting it"* ]]
}
