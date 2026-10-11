#!/usr/bin/env bats
# bin/egpu-sync: boot-time refresh of the DRM node variables.

setup_file() {
  load helpers/sandbox
  refuse_root
}

setup() {
  load helpers/sandbox
  make_root
}

@test "eGPU inactive: sync service disabled, kwin env removed, exit 0" {
  mkdir -p "$ROOT/home/deck/.config/plasma-workspace/env"
  touch "$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  run_script egpu-sync nvidia steamos
  assert_success
  assert_output --partial "Failsafe triggered"
  assert_called "systemctl disable xgmobile-boot-sync.service"
  assert [ ! -e "$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh" ]
}

@test "amd: skipped cleanly" {
  egpu_present amd
  local before
  before="$(cat "$ROOT/etc/environment")"
  run_script egpu-sync amd steamos
  assert_success
  assert_output --partial "Skipped cleanly"
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"
  refute_called "steamos-readonly"
}

@test "nvidia with both cards: WLR_DRM_DEVICES rewritten and kwin env refreshed" {
  egpu_present nvidia
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  mkdir -p "$ROOT/home/deck/.config/plasma-workspace/env"

  run_script egpu-sync nvidia steamos
  assert_success

  run grep WLR_DRM_DEVICES "$ROOT/etc/environment"
  assert_output "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run cat "$ROOT/home/deck/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  assert_line "export KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
}

@test "nvidia with the eGPU card missing: exit 1, environment untouched" {
  echo 1 > "$ROOT/sys/devices/platform/asus-nb-wmi/egpu_enable"
  echo "WLR_DRM_DEVICES=/dev/dri/card2:/dev/dri/card0" >> "$ROOT/etc/environment"
  local before
  before="$(cat "$ROOT/etc/environment")"
  run_script egpu-sync nvidia steamos
  assert_failure 1
  assert_output --partial "Failed to detect both GPUs"
  assert_equal "$(cat "$ROOT/etc/environment")" "$before"
}

@test "bazzite: skipped" {
  egpu_present nvidia
  run_script egpu-sync nvidia bazzite-nvidia
  assert_success
  assert_output --partial "Bazzite OS detected. Skipping."
}
