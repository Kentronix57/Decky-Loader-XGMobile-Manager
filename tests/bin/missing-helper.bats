#!/usr/bin/env bats
# Every script that sources bin/xgm-common.sh exits 9 before touching anything if it's missing.
# The scripts run from a copy in a temp bin dir; the real bin/xgm-common.sh is never touched.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
  # A state where each script would otherwise get well past its first command.
  nvidia_driver installed
  nvidia_configs backup
  enable_supergfxctl
  egpu_present nvidia
}

check_missing_helper() {
  run_without_helper "$@"
  assert_failure 9
  assert_line "ERROR: xgm-common.sh is missing. Reinstall XG Mobile Manager."
  assert_equal "$(cat "$SHIM_LOG")" ""
  assert_equal "$(find "$LOG_DIR" -mindepth 1)" ""
  assert [ ! -e "$DATA_DIR/configs" ]
}

@test "egpu-enable: helper missing, exit 9" { check_missing_helper egpu-enable nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"; }
@test "egpu-eject: helper missing, exit 9" { check_missing_helper egpu-eject nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"; }
@test "egpu-sync: helper missing, exit 9" { check_missing_helper egpu-sync "$LOG_DIR"; }
@test "create-shortcuts: helper missing, exit 9" {
  check_missing_helper create-shortcuts nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"
  assert [ ! -e "$ROOT/home/xgmtest/Desktop" ]
}
@test "supergfx-hybrid: helper missing, exit 9" { check_missing_helper supergfx-hybrid nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"; }
@test "supergfx-integrated: helper missing, exit 9" { check_missing_helper supergfx-integrated nvidia "$OS_TYPE" "$LOG_DIR" "$DATA_DIR"; }

@test "install-nvidia-cachyos.sh: helper missing, exit 9" {
  set_os cachyos
  check_missing_helper install-nvidia-cachyos.sh "$LOG_DIR" "$DATA_DIR"
}

@test "the real bin/xgm-common.sh is still there" {
  assert [ -f "$XGM_REPO/bin/xgm-common.sh" ]
}
