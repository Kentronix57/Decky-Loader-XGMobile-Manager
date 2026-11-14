#!/usr/bin/env bats
# Pre-flight checks of bin/install-nvidia.sh and bin/uninstall.sh: everything before they unlock
# the filesystem. steamos-readonly runs in fatal mode here, so a test that wrongly gets past the
# pre-flight is killed before the installer does anything else.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
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
  assert_output --partial "Remove them with pacman"
  refute_output --partial "supergfxctl"
}

# installer_exit_code is the EXIT trap's mapping: only the installer's own exits after the unlock
# (EXPLICIT_EXIT) keep their code; anything else becomes 1. Only that pure function is loaded
# here, so nothing after the unlock runs.
load_installer_exit_code() {
  eval "$(sed -n '/^installer_exit_code() {$/,/^}$/p' "$XGM_REPO/bin/install-nvidia.sh")"
  declare -F installer_exit_code >/dev/null
}

@test "install: the rollback keeps only explicit exit codes, everything else is 1" {
  load_installer_exit_code
  assert_equal "$(installer_exit_code 0 "")" 0
  assert_equal "$(installer_exit_code 5 5)" 5
  assert_equal "$(installer_exit_code 6 6)" 6
  assert_equal "$(installer_exit_code 11 11)" 11
  # dkms returns 10 when a build fails; 10 is "already installed" to the plugin.
  assert_equal "$(installer_exit_code 10 "")" 1
  assert_equal "$(installer_exit_code 1 "")" 1
  assert_equal "$(installer_exit_code 22 "")" 1
  assert_equal "$(installer_exit_code 143 "")" 1
  assert_equal "$(installer_exit_code 6 5)" 1
}
