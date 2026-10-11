#!/usr/bin/env bats
# Pre-flight checks of bin/install-nvidia.sh and bin/uninstall.sh: everything before they unlock
# the filesystem. steamos-readonly runs in fatal mode here, so a test that wrongly gets past the
# pre-flight is killed before the installer does anything else.

setup_file() {
  load helpers/sandbox
  refuse_root
}

setup() {
  load helpers/sandbox
  make_root
  touch "$SHIM_STATE/steamos_readonly_fatal"
  echo "6.11.11-valve12-1-neptune-611-gb3afa9aa9ae7" > "$SHIM_STATE/uname"
}

teardown() {
  refute_called "steamos-readonly"
}

@test "install: driver already loadable, exit 10" {
  nvidia_driver installed
  run_script install-nvidia.sh "$LOG_DIR" "$DATA_DIR"
  assert_failure 10
  assert_output --partial "ALREADY_INSTALLED NVIDIA Driver 610.43.02"
  refute_called "pacman"
}

@test "install: not SteamOS, exit 2" {
  local os
  for os in cachyos bazzite bazzite-nvidia; do
    set_os "$os"
    run_script install-nvidia.sh "$LOG_DIR" "$DATA_DIR"
    assert_failure 2
  done
}

@test "install: headers not in the repo (pacman -Si empty), exit 3" {
  run_script install-nvidia.sh "$LOG_DIR" "$DATA_DIR"
  assert_failure 3
  assert_called "pacman -Si linux-neptune-611-headers"
}

@test "install: header version doesn't match the kernel, exit 4" {
  echo "6.11.11.valve13-1" > "$SHIM_STATE/pacman_version"
  run_script install-nvidia.sh "$LOG_DIR" "$DATA_DIR"
  assert_failure 4
  assert_output --partial "Active Kernel: 6.11.11.valve12"
  assert_output --partial "Repository Headers: 6.11.11.valve13"
}

@test "uninstall: bazzite, exit 1" {
  set_os bazzite-nvidia
  run_script uninstall.sh "$LOG_DIR" "$DATA_DIR"
  assert_failure 1
  assert_output --partial "BazziteOS detected"
}

@test "uninstall: cachyos, exit 1" {
  set_os cachyos
  run_script uninstall.sh "$LOG_DIR" "$DATA_DIR"
  assert_failure 1
  assert_output --partial "CachyOS detected"
}
