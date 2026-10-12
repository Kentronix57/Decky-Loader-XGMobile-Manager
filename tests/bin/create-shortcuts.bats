#!/usr/bin/env bats
# bin/create-shortcuts: desktop launchers and the sudoers rule.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
  PLUGIN_DIR="$(readlink -f "$XGM_REPO")"
  DESKTOP="$ROOT/home/xgmtest/Desktop"
}

@test "steamos + nvidia + driver missing: exit 2, nothing written" {
  run_plugin_script create-shortcuts nvidia
  assert_failure 2
  assert [ ! -e "$ROOT/etc/sudoers.d/xgmobile-manager" ]
  assert [ ! -e "$DESKTOP" ]
}

@test "success: both .desktop files and the sudoers rule, with correct paths" {
  nvidia_driver installed
  run_plugin_script create-shortcuts nvidia
  assert_success
  assert_output --partial "Desktop shortcuts created successfully."

  run cat "$ROOT/etc/sudoers.d/xgmobile-manager"
  assert_output "xgmtest ALL=(root) NOPASSWD: $PLUGIN_DIR/bin/egpu-enable, $PLUGIN_DIR/bin/egpu-eject"

  assert [ -x "$DESKTOP/Enable XG Mobile.desktop" ]
  assert [ -x "$DESKTOP/Eject XG Mobile.desktop" ]
  run cat "$DESKTOP/Enable XG Mobile.desktop"
  assert_line "Name=Enable XG Mobile (nvidia)"
  assert_line "Exec=konsole -e bash -c \"sudo $PLUGIN_DIR/bin/egpu-enable nvidia steamos $LOG_DIR $DATA_DIR; sleep 3\""
  run cat "$DESKTOP/Eject XG Mobile.desktop"
  assert_line 'Exec=bash -c "touch /tmp/xgmobile_eject_request"'

  assert_called_before "steamos-readonly disable" "steamos-readonly enable"
  assert_called "chown xgmtest:xgmtest $DESKTOP/Enable XG Mobile.desktop"
}

@test "cachyos without steamos-readonly: shortcuts and sudoers rule still written" {
  set_os cachyos
  no_steamos_readonly
  nvidia_driver installed
  run_plugin_script create-shortcuts nvidia
  assert_success
  assert_output --partial "Desktop shortcuts created successfully."
  assert [ -f "$ROOT/etc/sudoers.d/xgmobile-manager" ]
  assert [ -x "$DESKTOP/Enable XG Mobile.desktop" ]
  refute_called "steamos-readonly"
}

@test "bazzite: no driver check and no steamos-readonly" {
  set_os bazzite-nvidia
  run_plugin_script create-shortcuts nvidia
  assert_success
  refute_called "modinfo"
  refute_called "steamos-readonly"
  assert [ -f "$DESKTOP/Enable XG Mobile.desktop" ]
}
