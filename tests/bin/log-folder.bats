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

NUKE_BANNER='echo "--- TOTAL SYSTEM RESTORATION ---"'

# nuke_header <script> [with-helper]: copies bin/<script> up to its banner (the first line after
# the log setup), then `exit 0`, into a fake plugin bin dir, with or without xgm-common.sh, and
# sets NUKE_DIR to that dir. Call it directly, never in $(...): a failed guard must stop the test.
nuke_header() {
  NUKE_DIR="$BATS_TEST_TMPDIR/hb/plugins/xgmobile-manager/bin"
  mkdir -p "$NUKE_DIR"
  sed "/^$NUKE_BANNER\$/q" "$XGM_REPO/bin/$1" > "$NUKE_DIR/$1"
  echo 'exit 0' >> "$NUKE_DIR/$1"
  if [ "${2:-}" = "with-helper" ]; then
    cp "$XGM_REPO/bin/xgm-common.sh" "$NUKE_DIR/"
  fi
  assert_safe_nuke_copy "$NUKE_DIR/$1"
}

# The reviewed nuke headers: every line of bin/<script> up to and including the banner, exactly.
# Only these lines (plus `exit 0`) are ever run by the tests. If the header of mega-nuke.sh or
# mega-nuke-dry.sh changes, review the new lines and update this deliberately: nothing in them may
# remove, move or overwrite anything outside the log folder.
reviewed_nuke_header() {
  case "$1" in
    mega-nuke.sh) cat <<'EOF'
#!/bin/bash
# Run by hand: show the output and keep a copy in the plugin's log folder. This is the emergency
# tool and may be downloaded on its own: without xgm-common.sh it still runs, with the output on
# the terminal only.
# shellcheck source=bin/xgm-common.sh
if . "$(dirname "$(readlink -f "$0")")/xgm-common.sh" 2>/dev/null; then
  LOG_DIR="${1:-$(xgm_log_dir)}"
  mkdir -p "$LOG_DIR" && exec > >(tee "$LOG_DIR/nuke.log") 2>&1
else
  echo "xgm-common.sh not found: not keeping a log file, output is on this terminal only."
fi
echo "--- TOTAL SYSTEM RESTORATION ---"
EOF
      ;;
    mega-nuke-dry.sh) cat <<'EOF'
#!/bin/bash
# Run by hand: show the output and keep a copy in the plugin's log folder (its own file, so a
# dry run never overwrites a real run's nuke.log). This is the emergency tool and may be downloaded
# on its own: without xgm-common.sh it still runs, with the output on the terminal only.
# shellcheck source=bin/xgm-common.sh
if . "$(dirname "$(readlink -f "$0")")/xgm-common.sh" 2>/dev/null; then
  LOG_DIR="${1:-$(xgm_log_dir)}"
  mkdir -p "$LOG_DIR" && exec > >(tee "$LOG_DIR/nuke_dry.log") 2>&1
else
  echo "xgm-common.sh not found: not keeping a log file, output is on this terminal only."
fi
echo "--- TOTAL SYSTEM RESTORATION ---"
EOF
      ;;
    *) return 1 ;;
  esac
}

# assert_safe_nuke_copy <file>: the copy is byte for byte the reviewed header plus `exit 0` (an
# allowlist, so no tab, find or redirect can slip in). Fails the test before anything runs.
assert_safe_nuke_copy() {
  local expected="$BATS_TEST_TMPDIR/reviewed-$(basename "$1")"
  { reviewed_nuke_header "$(basename "$1")" && echo 'exit 0'; } > "$expected" || {
    fail "no reviewed nuke header for $(basename "$1")"
    return 1
  }
  if ! cmp -s "$expected" "$1"; then
    fail "$(printf '%s is not the reviewed nuke header plus exit 0 (update reviewed_nuke_header deliberately):\n%s' \
      "$1" "$(diff "$expected" "$1")")"
    return 1
  fi
}

@test "mega-nuke.sh logs to activity/nuke.log, the dry run to nuke_dry.log" {
  local activity="$BATS_TEST_TMPDIR/hb/logs/xgmobile-manager/activity"
  nuke_header mega-nuke.sh with-helper
  assert_safe_nuke_copy "$NUKE_DIR/mega-nuke.sh"
  XGM_BIN_DIR="$NUKE_DIR" run_script mega-nuke.sh
  assert_success
  assert_output "--- TOTAL SYSTEM RESTORATION ---"
  assert_equal "$(cat "$activity/nuke.log")" "--- TOTAL SYSTEM RESTORATION ---"

  rm -rf "$BATS_TEST_TMPDIR/hb"
  nuke_header mega-nuke-dry.sh with-helper
  assert_safe_nuke_copy "$NUKE_DIR/mega-nuke-dry.sh"
  XGM_BIN_DIR="$NUKE_DIR" run_script mega-nuke-dry.sh
  assert_success
  assert_equal "$(cat "$activity/nuke_dry.log")" "--- TOTAL SYSTEM RESTORATION ---"
  assert [ ! -e "$activity/nuke.log" ]
}

@test "mega-nuke*.sh without xgm-common.sh: still runs, output on the terminal only" {
  local script
  for script in mega-nuke.sh mega-nuke-dry.sh; do
    rm -rf "$BATS_TEST_TMPDIR/hb"
    nuke_header "$script"
    assert [ ! -e "$NUKE_DIR/xgm-common.sh" ]
    assert_safe_nuke_copy "$NUKE_DIR/$script"
    XGM_BIN_DIR="$NUKE_DIR" run_script "$script"
    assert_success
    assert_line "xgm-common.sh not found: not keeping a log file, output is on this terminal only."
    assert_line "--- TOTAL SYSTEM RESTORATION ---"
    assert [ ! -e "$BATS_TEST_TMPDIR/hb/logs" ]
  done
}
