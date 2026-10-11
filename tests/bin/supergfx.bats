#!/usr/bin/env bats
# bin/supergfx-hybrid and bin/supergfx-integrated.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
}

check_success() {
  enable_supergfxctl
  run_plugin_script "$1" nvidia
  assert_success
  assert_called_before "systemctl start supergfxd.service" "supergfxctl -m $2"
  assert_called "systemctl restart sddm.service --no-block"
}

# The restart follows the display-manager alias: <script> <os> <dm alias> <expected unit>
check_dm() {
  enable_supergfxctl
  set_os "$2"
  set_dm "$3"
  run_plugin_script "$1" nvidia
  assert_success
  [[ "$LOG" == *"Display manager: $4"* ]]
  assert_called "systemctl restart $4 --no-block"
  assert_equal "$(calls_matching 'systemctl restart' | wc -l)" 1
}

check_supergfxctl_fails() {
  enable_supergfxctl
  export FAKE_SUPERGFX_RC=1
  run_plugin_script "$1" nvidia
  assert_failure 1
  assert_called "supergfxctl -m $2"
  refute_called "systemctl restart"
}

check_not_installed() {
  run_plugin_script "$1" nvidia
  assert_failure 2
  refute_called "systemctl"
  [[ "$LOG" == *"supergfxctl is not installed"* ]]
}

@test "supergfx-hybrid: success restarts sddm" { check_success supergfx-hybrid Hybrid; }
@test "supergfx-hybrid: supergfxctl fails, exit 1" { check_supergfxctl_fails supergfx-hybrid Hybrid; }
@test "supergfx-hybrid: supergfxctl not installed, exit 2" { check_not_installed supergfx-hybrid; }

@test "supergfx-hybrid: cachyos restarts plasmalogin" { check_dm supergfx-hybrid cachyos plasmalogin plasmalogin.service; }
@test "supergfx-hybrid: no alias falls back to sddm" { check_dm supergfx-hybrid cachyos none sddm.service; }

@test "supergfx-integrated: success restarts sddm" { check_success supergfx-integrated Integrated; }
@test "supergfx-integrated: cachyos restarts plasmalogin" { check_dm supergfx-integrated cachyos plasmalogin plasmalogin.service; }
@test "supergfx-integrated: no alias falls back to sddm" { check_dm supergfx-integrated cachyos none sddm.service; }
@test "supergfx-integrated: supergfxctl fails, exit 1" { check_supergfxctl_fails supergfx-integrated Integrated; }
@test "supergfx-integrated: supergfxctl not installed, exit 2" { check_not_installed supergfx-integrated; }
