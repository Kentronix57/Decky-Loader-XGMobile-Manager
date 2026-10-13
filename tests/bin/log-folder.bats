#!/usr/bin/env bats
# The plugin log folder: every script writes <LOG_DIR>/<name>.log, without the old
# xgmobile_manager_ prefix, and xgm_log_dir finds the activity/ subfolder of the one Decky uses
# (<homebrew>/logs/<plugin folder>/activity) for scripts that run without a log dir.

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

@test "xgm_log_dir: <homebrew>/logs/<plugin folder>/activity, from the plugin's location" {
  local dir
  dir=$(fake_install xgmobile-manager xgm-common.sh)
  run bash -c ". '$dir/xgm-common.sh' && xgm_log_dir"
  assert_success
  assert_output "$BATS_TEST_TMPDIR/hb/logs/xgmobile-manager/activity"

  # Decky names the folder after the plugin dir, whatever it is.
  dir=$(fake_install XGMobile-Manager xgm-common.sh)
  run bash -c ". '$dir/xgm-common.sh' && xgm_log_dir"
  assert_output "$BATS_TEST_TMPDIR/hb/logs/XGMobile-Manager/activity"
}

@test "egpu-sync with no arguments: boot_sync.log in the plugin log folder, created if missing" {
  local dir
  dir=$(fake_install xgmobile-manager egpu-sync)
  XGM_BIN_DIR="$dir" run_script egpu-sync
  assert_success
  assert_equal "$(find "$BATS_TEST_TMPDIR/hb/logs" -mindepth 1 -printf '%P\n' | sort)" \
    "$(printf '%s\n' xgmobile-manager xgmobile-manager/activity xgmobile-manager/activity/boot_sync.log)"
}

# nuke_header <script> [with-helper]: a copy of bin/<script> that stops right after its banner
# (the first line after the log setup), in a fake plugin bin dir, with or without xgm-common.sh.
# The nuke itself never runs. Prints the bin dir.
nuke_header() {
  local dir="$BATS_TEST_TMPDIR/hb/plugins/xgmobile-manager/bin"
  mkdir -p "$dir"
  sed '/^echo "--- TOTAL SYSTEM RESTORATION ---"$/q' "$XGM_REPO/bin/$1" > "$dir/$1"
  grep -qx 'echo "--- TOTAL SYSTEM RESTORATION ---"' "$dir/$1" || fail "$1: banner line not found"
  ! grep -qE 'steamos-readonly|pacman|rm ' "$dir/$1" || fail "$1: the header reaches the nuke"
  echo 'exit 0' >> "$dir/$1"
  [ "${2:-}" != "with-helper" ] || cp "$XGM_REPO/bin/xgm-common.sh" "$dir/"
  echo "$dir"
}

@test "mega-nuke.sh logs to activity/nuke.log, the dry run to nuke_dry.log" {
  local dir activity="$BATS_TEST_TMPDIR/hb/logs/xgmobile-manager/activity"
  dir=$(nuke_header mega-nuke.sh with-helper)
  XGM_BIN_DIR="$dir" run_script mega-nuke.sh
  assert_success
  assert_output "--- TOTAL SYSTEM RESTORATION ---"
  assert_equal "$(cat "$activity/nuke.log")" "--- TOTAL SYSTEM RESTORATION ---"

  rm -rf "$BATS_TEST_TMPDIR/hb"
  dir=$(nuke_header mega-nuke-dry.sh with-helper)
  XGM_BIN_DIR="$dir" run_script mega-nuke-dry.sh
  assert_success
  assert_equal "$(cat "$activity/nuke_dry.log")" "--- TOTAL SYSTEM RESTORATION ---"
  assert [ ! -e "$activity/nuke.log" ]
}

@test "mega-nuke*.sh without xgm-common.sh: still runs, output on the terminal only" {
  local script dir
  for script in mega-nuke.sh mega-nuke-dry.sh; do
    rm -rf "$BATS_TEST_TMPDIR/hb"
    dir=$(nuke_header "$script")
    assert [ ! -e "$dir/xgm-common.sh" ]
    XGM_BIN_DIR="$dir" run_script "$script"
    assert_success
    assert_line "xgm-common.sh not found: not keeping a log file, output is on this terminal only."
    assert_line "--- TOTAL SYSTEM RESTORATION ---"
    assert [ ! -e "$BATS_TEST_TMPDIR/hb/logs" ]
  done
}
