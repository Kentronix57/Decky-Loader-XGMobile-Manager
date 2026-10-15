#!/usr/bin/env bats
# bin/egpu-enable: exit codes, environment injection and per-OS branching.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
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
  refute_called "systemctl stop sddm.service"
  refute_called "systemctl start sddm.service"
}

@test "a saved result from an earlier run is dropped at the start, even when this run fails" {
  echo '{"timestamp": 0, "result": {}}' > "$DATA_DIR/last_result.json"
  date +%s > "$DATA_DIR/last_eject_cancelled"
  set_connected 0
  run_plugin_script egpu-enable nvidia
  assert_failure 1
  assert [ ! -e "$DATA_DIR/last_result.json" ]
  assert [ ! -e "$DATA_DIR/last_eject_cancelled" ]
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
  assert [ -f "$ROOT/home/xgmtest/xgmobile_configs_backup/nvidia_icd.json" ]
  run_plugin_script egpu-enable nvidia
  assert_failure 3
}

@test "old v0.2.0 location is looked up in the primary user's home, not /home/deck" {
  nvidia_driver installed
  mkdir -p "$ROOT/home/deck/xgmobile_configs_backup"
  echo '{}' > "$ROOT/home/deck/xgmobile_configs_backup/nvidia_icd.json"
  run_plugin_script egpu-enable nvidia
  assert_failure 4
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

@test "exit 6 after the display manager stopped: it is started again, exit code kept" {
  nvidia_ready steamos
  set_lspci empty
  run_plugin_script egpu-enable nvidia
  assert_failure 6
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_equal "$(calls_matching 'systemctl start sddm.service' | wc -l)" 1
  [[ "$LOG" == *"Restoring sddm.service after early exit or interruption..."* ]]
}

@test "exit 6 on cachyos: plasmalogin is started again, exit code kept" {
  nvidia_ready cachyos
  no_steamos_readonly
  set_lspci empty
  run_plugin_script egpu-enable nvidia
  assert_failure 6
  assert_called_before "systemctl stop plasmalogin.service" "systemctl start plasmalogin.service"
  refute_called "systemctl start sddm.service"
}

@test "exit 5 (before the display manager is stopped): display manager not touched" {
  egpu_appears never
  run_plugin_script egpu-enable amd
  assert_failure 5
  refute_called "systemctl stop sddm.service"
  refute_called "systemctl start sddm.service"
  [[ "$LOG" != *"after early exit or interruption"* ]]
}

@test "success: the display manager is started exactly once (no extra start from the trap)" {
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  assert_equal "$(calls_matching 'systemctl start sddm.service' | wc -l)" 1
  [[ "$LOG" != *"after early exit or interruption"* ]]
}

@test "an existing card10 doesn't hide a new card1" {
  touch "$ROOT/dev/dri/card10"
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  [[ "$LOG" == *"eGPU dynamically detected as: $ROOT/dev/dri/card1"$'\n'* ]]
  assert_called "setfacl -m u:xgmtest:rw $ROOT/dev/dri/card1"
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

  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_called "modprobe nvidia_drm modeset=1 fbdev=1"
  assert_called "setfacl -m u:xgmtest:rw $ROOT/dev/dri/card1"
  assert_equal "$(cat "$ROOT/etc/modprobe.d/nvidia-egpu.conf")" "options nvidia_drm modeset=1 fbdev=1"

  # NVIDIA configs re-fanged out of the backup
  assert [ -f "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
  assert [ -f "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ -f "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json" ]

  local plasma="$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  assert [ -x "$plasma" ]
  run cat "$plasma"
  assert_line "export KWIN_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
  assert_line "export GBM_BACKEND=nvidia-drm"

  assert_equal "$(readlink "$LOG_DIR/enable_latest.log")" "$LOG_DIR/enable_nvidia.log"
  refute_called "systemctl stop supergfxd.service"
}

@test "happy path cachyos/nvidia: same injection as steamos" {
  nvidia_ready cachyos
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_called "systemctl set-environment MESA_VK_DEVICE_SELECT=10de:2717"
  assert_called "modprobe nvidia_drm modeset=1 fbdev=1"
}

@test "steamos: display manager resolves to sddm.service, steamos-readonly used" {
  nvidia_ready steamos
  run_plugin_script egpu-enable nvidia
  assert_success
  [[ "$LOG" == *"Display manager: sddm.service"* ]]
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
}

@test "cachyos + plasmalogin: plasmalogin is stopped and started, sddm never touched" {
  nvidia_ready cachyos
  no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  [[ "$LOG" == *"Display manager: plasmalogin.service"* ]]
  assert_called_before "systemctl stop plasmalogin.service" "systemctl start plasmalogin.service"
  assert_equal "$(calls_matching sddm)" ""
  refute_called "steamos-readonly"
  [[ "$LOG" != *"command not found"* ]]
  assert [ -f "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json" ]
}

@test "cachyos: re-fang never overwrites a config pacman put back (mv -n)" {
  nvidia_ready cachyos
  no_steamos_readonly
  echo '{"from": "pacman"}' > "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json"
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json")" '{"from": "pacman"}'
  # The package's copy wins, so the stale backup is dropped.
  assert [ ! -e "$DATA_DIR/configs_backup/nvidia_icd.json" ]
  # Files with nothing in the way are still repaired.
  assert [ -f "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json" ]
  assert [ ! -e "$DATA_DIR/configs_backup/10_nvidia.json" ]
}

@test "cachyos: backup layer + package layer in implicit_layer.d: nothing in explicit_layer.d, backup removed" {
  nvidia_ready cachyos
  no_steamos_readonly
  echo '{"from": "pacman"}' > "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json"
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json")" '{"from": "pacman"}'
  assert [ ! -e "$ROOT/usr/share/vulkan/explicit_layer.d/nvidia_layers.json" ]
  assert [ ! -e "$DATA_DIR/configs_backup/nvidia_layers.json" ]
}

@test "cachyos: backup with no destination file: moved into place, nothing in explicit_layer.d" {
  nvidia_ready cachyos
  no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json")" '{"ICD": {"library_path": "libGLX_nvidia.so.0"}}'
  assert_equal "$(cat "$ROOT/usr/share/glvnd/egl_vendor.d/10_nvidia.json")" '{"ICD": {"library_path": "libEGL_nvidia.so.0"}}'
  assert_equal "$(cat "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json")" '{"layer": {"name": "VK_LAYER_NV_optimus"}}'
  assert [ ! -e "$ROOT/usr/share/vulkan/explicit_layer.d/nvidia_layers.json" ]
  assert_equal "$(find "$DATA_DIR/configs_backup" -type f)" ""
}

@test "steamos: re-fang unchanged (plain mv overwrites the existing layer)" {
  nvidia_ready steamos
  echo '{"existing": true}' > "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json"
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$ROOT/usr/share/vulkan/implicit_layer.d/nvidia_layers.json")" '{"layer": {"name": "VK_LAYER_NV_optimus"}}'
  assert [ ! -e "$ROOT/usr/share/vulkan/explicit_layer.d/nvidia_layers.json" ]
  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
}

@test "steamos: re-fang still restores the backup over an existing config" {
  nvidia_ready steamos
  echo '{"stale": true}' > "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json"
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$ROOT/usr/share/vulkan/icd.d/nvidia_icd.json")" '{"ICD": {"library_path": "libGLX_nvidia.so.0"}}'
}

@test "cachyos: nouveau is unloaded before the nvidia modules load" {
  nvidia_ready cachyos
  no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_called_before "modprobe -r nouveau" "modprobe nvidia_drm modeset=1 fbdev=1"
}

@test "steamos: nouveau is not touched" {
  nvidia_ready steamos
  run_plugin_script egpu-enable nvidia
  assert_success
  refute_called "modprobe -r nouveau"
}

@test "no display-manager alias: falls back to sddm.service" {
  egpu_appears amd
  set_os cachyos
  set_dm none
  run_plugin_script egpu-enable amd
  assert_success
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  [[ "$LOG" != *"unrecognized display manager"* ]]
}

# Unverified display managers keep today's behavior (sddm.service) and say so in the log.
check_dm_fallback() {
  egpu_appears amd
  set_os cachyos
  set_dm "$@"
  run_plugin_script egpu-enable amd
  assert_success
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_equal "$(calls_matching 'systemctl stop' | grep -vc sddm.service)" 0
  [[ "$LOG" == *"Display manager: sddm.service"* ]]
}

@test "gdm alias: not a verified display manager, falls back to sddm.service with a warning" {
  check_dm_fallback gdm
  [[ "$LOG" == *"WARNING: unrecognized display manager 'gdm.service', using sddm.service"* ]]
  refute_called "systemctl stop gdm.service"
}

@test "dangling plasmalogin alias: falls back to sddm.service with a warning" {
  check_dm_fallback plasmalogin dangling
  [[ "$LOG" == *"WARNING: unrecognized display manager 'plasmalogin.service', using sddm.service"* ]]
  refute_called "systemctl stop plasmalogin.service"
}

@test "alias not pointing at a .service unit: falls back to sddm.service with a warning" {
  check_dm_fallback bogus.target
  [[ "$LOG" == *"WARNING: unrecognized display manager 'bogus.target', using sddm.service"* ]]
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
  assert [ ! -e "$ROOT/home/xgmtest/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
  assert_called_before "systemctl stop sddm.service" "systemctl start sddm.service"
  assert_equal "$(readlink "$LOG_DIR/enable_latest.log")" "$LOG_DIR/enable_amd.log"
}

@test "bazzite + nvidia: modprobe sequence runs, /etc/environment untouched" {
  set_os bazzite-nvidia
  egpu_appears nvidia
  local before
  before="$(cat "$ROOT/etc/environment")"

  run_plugin_script egpu-enable nvidia
  assert_success

  assert_called_before "modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia" "modprobe nvidia_drm modeset=1 fbdev=1"
  assert_called "modprobe -a nvidia nvidia_modeset nvidia_uvm"
  assert_nvidia_services_after_modules
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
  assert_called_before "systemctl stop supergfxd.service" "systemctl stop sddm.service"
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

# The boot safety net is installed and enabled on every enable, not only during self-repair.
SYNC_UNIT=xgmobile-boot-sync.service

assert_sync_service_installed() {
  cmp "$XGM_REPO/assets/services/$SYNC_UNIT" "$ROOT/etc/systemd/system/$SYNC_UNIT"
  assert_called "systemctl enable $SYNC_UNIT"
  assert_called_before "systemctl daemon-reload" "systemctl enable $SYNC_UNIT"
  assert [ -e "$SHIM_STATE/enabled/$SYNC_UNIT" ]
}

sync_service_missing() {
  nvidia_ready "$1"
  [ "$1" = "cachyos" ] && no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  [[ "$LOG" != *"Initiating self-repair"* ]]
  [[ "$LOG" == *"Installing and enabling the boot safety net"* ]]
  assert_sync_service_installed
}

@test "steamos: boot service missing (no self-repair needed): copied, daemon-reload, enabled" {
  sync_service_missing steamos
  assert_called_before "steamos-readonly disable" "systemctl enable $SYNC_UNIT"
}

@test "cachyos: boot service missing (no self-repair needed): copied, daemon-reload, enabled" {
  sync_service_missing cachyos
}

@test "boot service installed but disabled (an older eject disabled it): enabled again" {
  egpu_appears amd
  sync_service_installed
  rm -f "$SHIM_STATE/enabled/$SYNC_UNIT"
  run_plugin_script egpu-enable amd
  assert_success
  assert_sync_service_installed
}

@test "boot service unit outdated: replaced and re-enabled" {
  egpu_appears amd
  sync_service_installed
  printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/egpu-sync nvidia steamos' > "$ROOT/etc/systemd/system/$SYNC_UNIT"
  run_plugin_script egpu-enable amd
  assert_success
  assert_sync_service_installed
}

# As seen on SteamOS: "Configuration file .../xgmobile-boot-sync.service is marked executable".
# cp kept the existing file's mode.
@test "boot service unit up to date but executable (755): reinstalled as 644" {
  egpu_appears amd
  sync_service_installed
  chmod 755 "$ROOT/etc/systemd/system/$SYNC_UNIT"
  run_plugin_script egpu-enable amd
  assert_success
  assert_sync_service_installed
  assert_equal "$(stat -c %a "$ROOT/etc/systemd/system/$SYNC_UNIT")" 644
}

@test "boot service unit outdated and executable (755): replaced as 644" {
  egpu_appears amd
  sync_service_installed
  printf '%s\n' '[Service]' 'ExecStart=/usr/local/bin/egpu-sync nvidia steamos' > "$ROOT/etc/systemd/system/$SYNC_UNIT"
  chmod 755 "$ROOT/etc/systemd/system/$SYNC_UNIT"
  run_plugin_script egpu-enable amd
  assert_success
  assert_sync_service_installed
  assert_equal "$(stat -c %a "$ROOT/etc/systemd/system/$SYNC_UNIT")" 644
}

@test "service files are never copied with cp (it keeps an executable destination's mode)" {
  run grep -nE '\bcp\b.*assets/services' "$XGM_REPO/bin/egpu-enable" "$XGM_REPO/bin/install-nvidia.sh"
  assert_output ""
  run grep -c 'install -m 644 "$REPO_ROOT/assets/services/' "$XGM_REPO/bin/install-nvidia.sh"
  assert_output 1
}

@test "boot service up to date and enabled: left alone" {
  egpu_appears amd
  sync_service_installed
  run_plugin_script egpu-enable amd
  assert_success
  refute_called "systemctl enable $SYNC_UNIT"
  refute_called "steamos-readonly"
}

@test "bazzite: boot service not installed (no environment injection there)" {
  set_os bazzite-nvidia
  egpu_appears nvidia
  run_plugin_script egpu-enable nvidia
  assert_success
  refute_called "systemctl enable $SYNC_UNIT"
  assert [ ! -e "$ROOT/etc/systemd/system/$SYNC_UNIT" ]
}

@test "the eGPU's PCI address is recorded for eject and the boot safety net" {
  nvidia_ready steamos
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$DATA_DIR/egpu_pci_address")" "0000:01:00.0"
  [[ "$LOG" == *"eGPU PCI address: 0000:01:00.0"* ]]
}

@test "PCI address recorded whatever the card number (eGPU as card0, iGPU as card1)" {
  gpu_numbering card1 renderD128 card0 renderD129
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  [[ "$LOG" == *"eGPU dynamically detected as: $ROOT/dev/dri/card0"* ]]
  assert_equal "$(cat "$DATA_DIR/egpu_pci_address")" "0000:01:00.0"
}

@test "bazzite: PCI address recorded too" {
  set_os bazzite-nvidia
  egpu_appears nvidia
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(cat "$DATA_DIR/egpu_pci_address")" "0000:01:00.0"
}

@test "boot service installed and enabled, but /usr/local/bin/egpu-sync missing: symlink created" {
  egpu_appears amd
  sync_service_installed
  rm -f "$ROOT/usr/local/bin/egpu-sync"
  run_plugin_script egpu-enable amd
  assert_success
  assert_equal "$(readlink "$ROOT/usr/local/bin/egpu-sync")" "$(readlink -f "$XGM_REPO/bin/egpu-sync")"
  assert [ -x "$ROOT/usr/local/bin/egpu-sync" ]
  assert_sync_service_installed
}

# nvidia-persistenced and nvidia-powerd (Dynamic Boost) need the eGPU and its modules: stopped
# before the modules reload, and started only once they're loaded. Before this, SteamOS/CachyOS
# started them ahead of the eGPU, where they exit, which left the XG Mobile at its default power
# limit (115 W instead of 150 W on the 4090).
assert_nvidia_services_after_modules() {
  local start first_start reload
  start="systemctl start nvidia-persistenced nvidia-powerd"
  assert_called_before "systemctl stop nvidia-powerd nvidia-persistenced" "modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia"
  assert_called_before "modprobe -a nvidia nvidia_modeset nvidia_uvm" "$start"
  assert_called "systemctl enable nvidia-persistenced nvidia-powerd"
  # No NVIDIA service is started anywhere before the modules are loaded.
  first_start=$(grep -nE '^systemctl (re)?start nvidia-(persistenced|powerd)' "$SHIM_LOG" | head -n 1 | cut -d: -f1)
  reload=$(grep -Fxn -- "modprobe -a nvidia nvidia_modeset nvidia_uvm" "$SHIM_LOG" | head -n 1 | cut -d: -f1)
  [ "$first_start" -gt "$reload" ] || fail "an NVIDIA service was started (line $first_start) before the modules loaded (line $reload)"
}

@test "steamos + nvidia: NVIDIA services start after the modules load, not before the eGPU is on" {
  nvidia_ready steamos
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_nvidia_services_after_modules
  [[ "$LOG" == *"Starting NVIDIA services (persistence, Dynamic Boost)..."* ]]
}

@test "steamos + nvidia with self-repair (as on real installs): no NVIDIA service started early, unit files installed as 644" {
  nvidia_ready steamos
  rm "$ROOT/etc/systemd/system/nvidia-suspend.service"
  # Self-repair chmods and links the plugin's own files, so run a copy inside the sandbox.
  local plugin="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$plugin"
  cp -r "$XGM_REPO/bin" "$XGM_REPO/assets" "$plugin/"
  # Unit files an older version left executable.
  local unit
  for unit in egpu-enable.service egpu-eject.service xgmobile-boot-sync.service; do
    cp "$XGM_REPO/assets/services/$unit" "$ROOT/etc/systemd/system/$unit"
    chmod 755 "$ROOT/etc/systemd/system/$unit"
  done
  XGM_BIN_DIR="$plugin/bin" ALLOW_SELF_REPAIR=1 run_script egpu-enable nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"
  assert_success
  [[ "$LOG" == *"Initiating self-repair"* ]]
  assert_nvidia_services_after_modules
  for unit in egpu-enable.service egpu-eject.service xgmobile-boot-sync.service; do
    cmp "$XGM_REPO/assets/services/$unit" "$ROOT/etc/systemd/system/$unit"
    assert_equal "$unit $(stat -c %a "$ROOT/etc/systemd/system/$unit")" "$unit 644"
  done
}

@test "cachyos + nvidia: NVIDIA services start after the modules load, not before the eGPU is on" {
  nvidia_ready cachyos
  no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_nvidia_services_after_modules
}

@test "amd: NVIDIA services are left alone" {
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  if grep -nE 'nvidia-(powerd|persistenced)' "$SHIM_LOG"; then
    fail "AMD enable touched an NVIDIA service"
  fi
}

@test "nvidia modules: nvidia_drm with its options, then the others with modprobe -a" {
  nvidia_ready cachyos
  no_steamos_readonly
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_called_before "modprobe nvidia_drm modeset=1 fbdev=1" "modprobe -a nvidia nvidia_modeset nvidia_uvm"
  refute_called "modprobe nvidia_modeset"
  assert [ -d "$ROOT/sys/module/nvidia_uvm" ]
}

@test "primary user: Steam not running, first regular user with a home dir" {
  steam_not_running
  mkdir -p "$ROOT/home/nohome"
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  assert_called "sudo -u nohome XDG_RUNTIME_DIR=/run/user/64999 systemctl --user set-environment WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
}

@test "primary user: Steam running as deck stays deck" {
  steam_user deck
  egpu_appears amd
  run_plugin_script egpu-enable amd
  assert_success
  assert_called "sudo -u deck XDG_RUNTIME_DIR=/run/user/64999 systemctl --user set-environment WLR_DRM_DEVICES=$ROOT/dev/dri/card1:$ROOT/dev/dri/card0"
}
