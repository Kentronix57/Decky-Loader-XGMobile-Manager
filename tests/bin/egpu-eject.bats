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

@test "eGPU PCI device drops: success logged without the 15 s wait, sddm restarted, egpu_enable cleared" {
  egpu_present amd
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"Success! eGPU 0000:01:00.0 dropped from the PCIe bus. eGPU safely detached."* ]]
  [[ "$LOG" != *"WARNING"* ]]
  assert_equal "$(grep -c '^sleep 1$' "$SHIM_LOG")" 1
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

# Every fuser call got the eGPU's nodes ($1 $2) and none of the iGPU's ($3 $4).
assert_fuser_only_egpu_nodes() {
  local line
  [ -n "$(calls_matching 'fuser ')" ] || fail "fuser was never called"
  while IFS= read -r line; do
    line="$line "
    [[ "$line" == *"/dev/dri/$1 "* && "$line" == *"/dev/dri/$2 "* ]] || fail "eGPU nodes $1/$2 missing from: $line"
    [[ "$line" != *"/dev/dri/$3 "* ]] || fail "iGPU node $3 passed to fuser: $line"
    [[ "$line" != *"/dev/dri/$4 "* ]] || fail "iGPU node $4 passed to fuser: $line"
  done < <(calls_matching 'fuser ')
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
  assert_called_before "fuser -k -TERM $ROOT/dev/dri/card1 $ROOT/dev/dri/renderD129 $ROOT/dev/nvidia-modeset $ROOT/dev/nvidia0 $ROOT/dev/nvidiactl" "modprobe -r nvidia_drm"
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

@test "safety stop: nvidia_drm can't be unloaded, eject cancelled with exit 7" {
  set_os cachyos
  no_steamos_readonly
  egpu_present nvidia
  module_stuck nvidia_drm
  echo "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0" >> "$ROOT/etc/environment"
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled plasmalogin.service
  [[ "$LOG" == *"nvidia_drm is still loaded"* ]]
  assert [ -e "$ROOT/sys/module/nvidia_drm" ]
  assert [ -e "$ROOT/sys/class/drm/card1" ]
  [[ "$LOG" != *"Success!"* ]]
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
}

@test "safety stop on bazzite: same cancel, overlay fixes not applied" {
  set_os bazzite-nvidia
  no_steamos_readonly
  egpu_present nvidia
  module_stuck nvidia_drm
  cp "$ROOT/etc/environment" "$BATS_TEST_TMPDIR/environment.before"
  run_plugin_script egpu-eject nvidia
  assert_cancelled sddm.service
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

@test "active but no eGPU DRM card: release and wait skipped, egpu_enable still cleared" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"No eGPU found. Skipping the GPU release."* ]]
  refute_called "fuser"
  refute_called "sleep"
  assert_equal "$(cat "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable")" 0
}

@test "AMD eGPU: identified by boot_vga even though both cards are 0x1002" {
  egpu_present amd
  assert_equal "$(cat "$ROOT/sys/class/drm/card1/device/vendor")" "0x1002"
  # A connector entry has no boot_vga either; it must not count as a GPU.
  mkdir -p "$ROOT/sys/class/drm/card0-eDP-1/device"
  run_plugin_script egpu-eject amd
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129)"* ]]
  assert_equal "$(grep -c '^eGPU: ' <<< "$LOG")" 1
  assert_fuser_only_egpu_nodes card1 renderD129 card0 renderD128
}

# Card numbers aren't stable across boots: the captured Ally had the eGPU as card0 with
# renderD129, and the iGPU's renderD128 held by steamwebhelper. eject_with_numbering <eGPU card>
# <eGPU render> <iGPU card> <iGPU render> <record|no-record>
eject_with_numbering() {
  gpu_numbering "$3" "$4" "$1" "$2"
  [ "$5" = "record" ] && record_egpu_pci
  egpu_present nvidia
  gpu_holders 100
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 ($1 $2)"* ]] || fail "eGPU nodes not resolved as $1 $2: $LOG"
  assert_fuser_only_egpu_nodes "$1" "$2" "$3" "$4"
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
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129)"* ]]
  assert_called "modprobe -r nvidia_drm"
}

@test "no record and no non-boot-VGA card: no eGPU found, release skipped" {
  egpu_present nvidia
  echo 1 > "$ROOT/sys/class/drm/card1/device/boot_vga"
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"No eGPU found. Skipping the GPU release."* ]]
  refute_called "fuser"
  refute_called "modprobe"
}

@test "recorded address that no longer exists: boot_vga fallback" {
  record_egpu_pci 0000:05:00.0
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129)"* ]]
}

@test "malformed record is ignored: boot_vga fallback" {
  record_egpu_pci "../../../../etc"
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  [[ "$LOG" == *"eGPU: 0000:01:00.0 (card1 renderD129)"* ]]
}

@test "eject never disables the boot safety net" {
  sync_service_installed
  egpu_present nvidia
  run_plugin_script egpu-eject nvidia
  assert_success
  refute_called "systemctl disable xgmobile-boot-sync.service"
  assert [ -e "$SHIM_STATE/enabled/xgmobile-boot-sync.service" ]
}
