#!/usr/bin/env bats
# bin/migrate-logs: moves the logs older versions wrote to <homebrew>/logs into the plugin's log
# folder, without the old prefixes. Nothing is overwritten, and a second run changes nothing.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
  LOGS_ROOT="$(dirname "$LOG_DIR")"
  SHORTCUT="$ROOT/home/xgmtest/Desktop/Enable XG Mobile.desktop"
  # main.py's arguments. LOG_DIR holds seeded files, so run_script mustn't empty it.
  export KEEP_LOG_DIR=1
}

run_migrate() { run_script migrate-logs "$LOGS_ROOT" "$LOG_DIR"; }

# old <name> [content]: a log an older version left in LOGS_ROOT.
old() { printf '%s\n' "${2:-old $1}" > "$LOGS_ROOT/$1"; }

# Every path, type, size, mtime and link target under homebrew/ and the sandbox home dirs, plus
# every file's checksum: equal snapshots mean nothing was touched.
snapshot() {
  find "$BATS_TEST_TMPDIR/homebrew" "$ROOT/home" -printf '%p|%y|%s|%T@|%l\n' | sort
  find "$BATS_TEST_TMPDIR/homebrew" "$ROOT/home" -type f -exec md5sum {} + | sort
}

# A shortcut as create-shortcuts wrote it before the log folder, passing <homebrew>/logs.
old_shortcut() {
  mkdir -p "$(dirname "$SHORTCUT")"
  cat > "$SHORTCUT" <<EOF
[Desktop Entry]
Name=Enable XG Mobile (nvidia)
Comment=Activates the eGPU and restarts the display
Exec=konsole -e bash -c "sudo /plugin/bin/egpu-enable nvidia steamos $LOGS_ROOT $DATA_DIR; sleep 3"
Icon=video-display
Terminal=false
Type=Application
Categories=Utility;
EOF
  chmod 755 "$SHORTCUT"
}

@test "prefixed logs: moved into the plugin folder and renamed, summary in migrate.log" {
  old xgmobile_manager_enable_nvidia.log
  old xgmobile_manager_eject_amd.log
  old xgmobile_manager_python_crash.log
  old xgmobile_manager_boot_sync.log
  run_migrate
  assert_success
  assert_output ""
  assert_equal "$(cat "$LOG_DIR/enable_nvidia.log")" "old xgmobile_manager_enable_nvidia.log"
  assert_equal "$(cat "$LOG_DIR/eject_amd.log")" "old xgmobile_manager_eject_amd.log"
  assert_equal "$(cat "$LOG_DIR/python_crash.log")" "old xgmobile_manager_python_crash.log"
  assert_equal "$(cat "$LOG_DIR/boot_sync.log")" "old xgmobile_manager_boot_sync.log"
  assert_equal "$(compgen -G "$LOGS_ROOT/xgmobile_*")" ""

  run cat "$LOG_DIR/migrate.log"
  assert_line --regexp '^--- Log migration at '
  assert_line "Moved $LOGS_ROOT/xgmobile_manager_enable_nvidia.log -> $LOG_DIR/enable_nvidia.log"
}

@test "legacy xgmobile_ logs: moved and renamed" {
  old xgmobile_desktop_eject_request.log
  old xgmobile_transition.log
  run_migrate
  assert_success
  assert_equal "$(cat "$LOG_DIR/desktop_eject_request.log")" "old xgmobile_desktop_eject_request.log"
  assert_equal "$(cat "$LOG_DIR/transition.log")" "old xgmobile_transition.log"
  assert [ ! -e "$LOGS_ROOT/xgmobile_transition.log" ]
}

@test "collision: the old file goes to archive/, then archive/<name>.<mtime>; nothing is overwritten" {
  echo "new enable" > "$LOG_DIR/enable_nvidia.log"
  old xgmobile_manager_enable_nvidia.log "prefixed enable"
  old xgmobile_enable_nvidia.log "legacy enable"
  touch -d @1700000000 "$LOGS_ROOT/xgmobile_enable_nvidia.log"
  mkdir -p "$LOG_DIR/archive"
  echo "archived" > "$LOG_DIR/archive/transition.log"
  echo "archived 2" > "$LOG_DIR/archive/transition.log.1700000001"
  old xgmobile_manager_transition.log "old transition"
  echo "new transition" > "$LOG_DIR/transition.log"
  touch -d @1700000001 "$LOGS_ROOT/xgmobile_manager_transition.log"

  run_migrate
  assert_success
  assert_equal "$(cat "$LOG_DIR/enable_nvidia.log")" "new enable"
  # The legacy and prefixed files both collide; the glob sorts xgmobile_enable_ first.
  assert_equal "$(cat "$LOG_DIR/archive/enable_nvidia.log")" "legacy enable"
  assert_equal "$(cat "$LOG_DIR/archive/enable_nvidia.log."*)" "prefixed enable"
  assert_equal "$(cat "$LOG_DIR/transition.log")" "new transition"
  assert_equal "$(cat "$LOG_DIR/archive/transition.log")" "archived"
  assert_equal "$(cat "$LOG_DIR/archive/transition.log.1700000001")" "archived 2"
  assert_equal "$(cat "$LOG_DIR/archive/transition.log.1700000001.1")" "old transition"
  assert_equal "$(compgen -G "$LOGS_ROOT/xgmobile_*")" ""
}

@test "_latest links: old ones removed, new ones point at the migrated vendor log (nvidia first)" {
  old xgmobile_manager_enable_nvidia.log
  old xgmobile_manager_enable_amd.log
  old xgmobile_manager_eject_amd.log
  ln -s "$LOGS_ROOT/xgmobile_manager_enable_amd.log" "$LOGS_ROOT/xgmobile_manager_enable_latest.log"
  ln -s "$LOGS_ROOT/xgmobile_manager_eject_amd.log" "$LOGS_ROOT/xgmobile_manager_eject_latest.log"
  run_migrate
  assert_success
  assert [ ! -L "$LOGS_ROOT/xgmobile_manager_enable_latest.log" ]
  assert [ ! -L "$LOGS_ROOT/xgmobile_manager_eject_latest.log" ]
  assert_equal "$(readlink "$LOG_DIR/enable_latest.log")" "$LOG_DIR/enable_nvidia.log"
  assert_equal "$(readlink "$LOG_DIR/eject_latest.log")" "$LOG_DIR/eject_amd.log"
  # A link is never moved as a log.
  assert [ ! -e "$LOG_DIR/archive" ]
}

@test "_latest links: an existing new link is kept" {
  old xgmobile_manager_enable_nvidia.log
  ln -s "$LOGS_ROOT/xgmobile_manager_enable_nvidia.log" "$LOGS_ROOT/xgmobile_manager_enable_latest.log"
  echo "amd" > "$LOG_DIR/enable_amd.log"
  ln -s "$LOG_DIR/enable_amd.log" "$LOG_DIR/enable_latest.log"
  run_migrate
  assert_success
  assert_equal "$(readlink "$LOG_DIR/enable_latest.log")" "$LOG_DIR/enable_amd.log"
  assert [ ! -L "$LOGS_ROOT/xgmobile_manager_enable_latest.log" ]
}

@test "failed DKMS builds: moved to dkms/ only when they hold build/make.log" {
  mkdir -p "$LOGS_ROOT/nvidia/580.82.09/build" "$LOGS_ROOT/nvidia-open/580.82.09" "$LOGS_ROOT/nvidiaish"
  echo "make failed" > "$LOGS_ROOT/nvidia/580.82.09/build/make.log"
  echo "no build dir" > "$LOGS_ROOT/nvidia-open/580.82.09/notes"
  echo "a file" > "$LOGS_ROOT/nvidia-settings.log"
  run_migrate
  assert_success
  assert_equal "$(cat "$LOG_DIR/dkms/nvidia/580.82.09/build/make.log")" "make failed"
  assert [ ! -e "$LOGS_ROOT/nvidia" ]
  assert [ -f "$LOGS_ROOT/nvidia-open/580.82.09/notes" ]
  assert [ -d "$LOGS_ROOT/nvidiaish" ]
  assert [ -f "$LOGS_ROOT/nvidia-settings.log" ]
  assert [ ! -e "$LOG_DIR/dkms/nvidia-open" ]
}

@test "failed DKMS builds: an existing dkms/<name> isn't overwritten" {
  mkdir -p "$LOGS_ROOT/nvidia/1/build" "$LOG_DIR/dkms/nvidia"
  echo "old build" > "$LOGS_ROOT/nvidia/1/build/make.log"
  echo "newer" > "$LOG_DIR/dkms/nvidia/keep"
  touch -d @1700000000 "$LOGS_ROOT/nvidia"
  run_migrate
  assert_success
  assert_equal "$(cat "$LOG_DIR/dkms/nvidia/keep")" "newer"
  assert_equal "$(cat "$LOG_DIR/dkms/nvidia.1700000000/1/build/make.log")" "old build"
}

@test "old desktop shortcut: the log dir argument is rewritten, exactly once" {
  old_shortcut
  local expected
  expected=$(sed "s# $LOGS_ROOT # $LOG_DIR #" "$SHORTCUT")
  # Another user's shortcut, for a different homebrew, is left alone.
  mkdir -p "$ROOT/home/other/Desktop"
  sed "s#$LOGS_ROOT#/home/other/homebrew/logs#" "$SHORTCUT" > "$ROOT/home/other/Desktop/Enable XG Mobile.desktop"
  local other
  other=$(cat "$ROOT/home/other/Desktop/Enable XG Mobile.desktop")

  run_migrate
  assert_success
  assert_equal "$(cat "$SHORTCUT")" "$expected"
  run grep -c "egpu-enable nvidia steamos $LOG_DIR $DATA_DIR; sleep 3\"$" "$SHORTCUT"
  assert_output 1
  assert [ -x "$SHORTCUT" ]
  assert_equal "$(cat "$ROOT/home/other/Desktop/Enable XG Mobile.desktop")" "$other"
  run cat "$LOG_DIR/migrate.log"
  assert_line "Updated the log dir in $SHORTCUT"

  run_migrate
  assert_success
  assert_equal "$(cat "$SHORTCUT")" "$expected"
}

@test "a shortcut create-shortcuts already wrote with the new dir is left alone" {
  old_shortcut
  sed -i "s# $LOGS_ROOT # $LOG_DIR #" "$SHORTCUT"
  local before
  before=$(snapshot)
  run_migrate
  assert_success
  assert_equal "$(snapshot)" "$before"
}

@test "Decky's timestamped logs, other plugins' logs and unrelated files are untouched" {
  echo "decky" > "$LOG_DIR/2026-10-12 21.04.33.log"
  mkdir -p "$LOGS_ROOT/SimpleDeckyTDP"
  echo "tdp" > "$LOGS_ROOT/SimpleDeckyTDP/2026-10-12 21.04.33.log"
  echo "loader" > "$LOGS_ROOT/loader.log"
  echo "notes" > "$LOGS_ROOT/xgmobile_notes.txt"
  echo "empty name" > "$LOGS_ROOT/xgmobile_.log"
  mkdir -p "$LOGS_ROOT/xgmobile_dir.log"
  mkdir -p "$LOGS_ROOT/sub"
  echo "nested" > "$LOGS_ROOT/sub/xgmobile_manager_enable_nvidia.log"
  local before
  before=$(snapshot)
  run_migrate
  assert_success
  assert_output ""
  assert_equal "$(snapshot)" "$before"
  assert [ ! -e "$LOG_DIR/migrate.log" ]
}

@test "second run: no-op (nothing moved, migrate.log unchanged, no output)" {
  old xgmobile_manager_enable_nvidia.log
  old xgmobile_manager_eject_nvidia.log
  old xgmobile_transition.log
  ln -s "$LOGS_ROOT/xgmobile_manager_enable_nvidia.log" "$LOGS_ROOT/xgmobile_manager_enable_latest.log"
  echo "new" > "$LOG_DIR/eject_nvidia.log"
  mkdir -p "$LOGS_ROOT/nvidia/1/build"
  echo "x" > "$LOGS_ROOT/nvidia/1/build/make.log"
  old_shortcut
  run_migrate
  assert_success
  assert [ -f "$LOG_DIR/migrate.log" ]

  local before
  before=$(snapshot)
  run_migrate
  assert_success
  assert_output ""
  assert_equal "$(snapshot)" "$before"
}

@test "nothing to migrate, or no logs root: exit 0, nothing created" {
  local before
  before=$(snapshot)
  run_migrate
  assert_success
  assert_output ""
  assert_equal "$(snapshot)" "$before"

  run_script migrate-logs "$BATS_TEST_TMPDIR/missing" "$BATS_TEST_TMPDIR/missing/xgmobile-manager"
  assert_success
  assert [ ! -e "$BATS_TEST_TMPDIR/missing" ]
}

@test "no arguments: <homebrew>/logs into <homebrew>/logs/<plugin folder>, from the plugin's location" {
  local hb="$BATS_TEST_TMPDIR/hb" dir
  dir="$hb/plugins/xgmobile-manager/bin"
  mkdir -p "$dir" "$hb/logs"
  cp "$XGM_REPO/bin/migrate-logs" "$XGM_REPO/bin/xgm-common.sh" "$dir/"
  echo "old" > "$hb/logs/xgmobile_manager_install.log"
  XGM_BIN_DIR="$dir" run_script migrate-logs
  assert_success
  assert_equal "$(cat "$hb/logs/xgmobile-manager/install.log")" "old"
  assert [ -f "$hb/logs/xgmobile-manager/migrate.log" ]
}
