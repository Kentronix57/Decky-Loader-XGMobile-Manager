#!/usr/bin/env bats
# The plugin log folder: every script writes <LOG_DIR>/<name>.log, without the old
# xgmobile_manager_ prefix, and xgm_log_dir finds the same folder Decky uses
# (<homebrew>/logs/<plugin folder>) for scripts that run without a log dir.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
}

# The names of everything the last run left in LOG_DIR, one per line, sorted.
log_names() { find "$LOG_DIR" -mindepth 1 -printf '%P\n' | sort; }

@test "egpu-enable + egpu-eject (nvidia): enable_nvidia.log, eject_nvidia.log and the _latest links" {
  nvidia_driver installed
  nvidia_configs backup
  egpu_appears nvidia
  run_plugin_script egpu-enable nvidia
  assert_success
  assert_equal "$(log_names)" "$(printf '%s\n' enable_latest.log enable_nvidia.log)"
  assert_equal "$(readlink "$LOG_DIR/enable_latest.log")" "$LOG_DIR/enable_nvidia.log"

  run_plugin_script egpu-eject nvidia
  assert_success
  assert_equal "$(log_names)" "$(printf '%s\n' eject_latest.log eject_nvidia.log)"
  assert_equal "$(readlink "$LOG_DIR/eject_latest.log")" "$LOG_DIR/eject_nvidia.log"
}

@test "supergfx-hybrid / supergfx-integrated: supergfxd_<mode>.log" {
  enable_supergfxctl
  run_plugin_script supergfx-hybrid nvidia
  assert_success
  assert_equal "$(log_names)" "supergfxd_hybrid.log"
  run_plugin_script supergfx-integrated nvidia
  assert_success
  assert_equal "$(log_names)" "supergfxd_integrated.log"
}

@test "egpu-sync with a log dir: boot_sync.log" {
  run_script egpu-sync "$LOG_DIR" "$DATA_DIR"
  assert_success
  assert_equal "$(log_names)" "boot_sync.log"
}

@test "no script writes a prefixed log name" {
  # Only migrate-logs may name the old files.
  run grep -rnE --exclude=migrate-logs 'xgmobile(_manager)?_[A-Za-z_${}]+\.log' "$XGM_REPO/bin"
  assert_output ""
}

# Copies bin/<name> and xgm-common.sh to <homebrew>/plugins/<plugin>/bin in the sandbox and prints
# that bin dir.
fake_install() {
  local dir="$BATS_TEST_TMPDIR/hb/plugins/$1/bin"
  mkdir -p "$dir"
  cp "$XGM_REPO/bin/xgm-common.sh" "$XGM_REPO/bin/$2" "$dir/"
  echo "$dir"
}

@test "xgm_log_dir: <homebrew>/logs/<plugin folder>, from the plugin's location" {
  local dir
  dir=$(fake_install xgmobile-manager xgm-common.sh)
  run bash -c ". '$dir/xgm-common.sh' && xgm_log_dir"
  assert_success
  assert_output "$BATS_TEST_TMPDIR/hb/logs/xgmobile-manager"

  # Decky names the folder after the plugin dir, whatever it is.
  dir=$(fake_install XGMobile-Manager xgm-common.sh)
  run bash -c ". '$dir/xgm-common.sh' && xgm_log_dir"
  assert_output "$BATS_TEST_TMPDIR/hb/logs/XGMobile-Manager"
}

@test "egpu-sync with no arguments: boot_sync.log in the plugin log folder, created if missing" {
  local dir
  dir=$(fake_install xgmobile-manager egpu-sync)
  XGM_BIN_DIR="$dir" run_script egpu-sync
  assert_success
  assert_equal "$(find "$BATS_TEST_TMPDIR/hb/logs" -mindepth 1 -printf '%P\n' | sort)" \
    "$(printf '%s\n' xgmobile-manager xgmobile-manager/boot_sync.log)"
}

# The nuke scripts are run by hand and never executed by the tests; check their log names.
@test "mega-nuke.sh logs to nuke.log, the dry run to nuke_dry.log" {
  run grep -F 'tee "$LOG_DIR/nuke.log"' "$XGM_REPO/bin/mega-nuke.sh"
  assert_success
  run grep -F 'tee "$LOG_DIR/nuke_dry.log"' "$XGM_REPO/bin/mega-nuke-dry.sh"
  assert_success
  run grep -F 'nuke.log"' "$XGM_REPO/bin/mega-nuke-dry.sh"
  assert_failure
}
