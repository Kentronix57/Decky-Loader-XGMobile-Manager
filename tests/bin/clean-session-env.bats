#!/usr/bin/env bats
# bin/clean-session-env (xgm_clean_session_env): unsets the eGPU variables in the system and user
# systemd managers right before the desktop Eject link switches to Game Mode. Only values we set
# are unset, and every manager's state is logged before and after.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
  # The wait for the user session (xgm_wait_for_user_session): one tick per check, capped at 20.
  export XGM_WAIT_POLL=0.01 XGM_WAIT_CAP=0.2
}

# run_clean [known session ids]
run_clean() { run_script clean-session-env xgmtest "$LOG_DIR" "$@"; }

# The line number of the first (line_first) or last (line_last) shim log line equal to the text, or 0.
line_first() { grep -Fxn -- "$1" "$SHIM_LOG" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
line_last() { grep -Fxn -- "$1" "$SHIM_LOG" | tail -n 1 | cut -d: -f1 | grep . || echo 0; }

# How many shim log lines equal the text, before line <n>.
count_before() { head -n "$(($2 - 1))" "$SHIM_LOG" | grep -cFx -- "$1" || true; }

# The user manager calls, as the wait and the cleanup make them.
as_user() { echo "setpriv --reuid=64999 --regid=64999 --init-groups env XDG_RUNTIME_DIR=$ROOT/run/user/64999 systemctl --user $*"; }

# What egpu-enable injects, plus what Plasma imports from xgmobile-nvidia-kwin.sh.
EGPU_ENV=(
  "MESA_VK_DEVICE_SELECT=10de:2717"
  "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json"
  "WLR_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  "VK_LOADER_LAYERS_DISABLE=*"
  "GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT=1"
  "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  "GBM_BACKEND=nvidia-drm"
  "__GLX_VENDOR_LIBRARY_NAME=nvidia"
)
EGPU_NAMES="MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT KWIN_DRM_DEVICES GBM_BACKEND __GLX_VENDOR_LIBRARY_NAME"

@test "user manager holds the 5 + 3 eGPU variables with our values: all unset, before and after logged" {
  set_os cachyos
  manager_env user "LANG=en_US.UTF-8" "${EGPU_ENV[@]}" "XDG_SESSION_TYPE=wayland"
  manager_env system "PATH=/usr/bin" "${EGPU_ENV[@]:0:5}"
  run_clean
  assert_success
  assert_output ""
  assert_equal "$(manager_env_of user)" "$(printf '%s\n' "LANG=en_US.UTF-8" "XDG_SESSION_TYPE=wayland")"
  assert_equal "$(manager_env_of system)" "PATH=/usr/bin"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line --regexp '^--- Session environment cleanup for xgmtest at '
  assert_line "eGPU variables found in system manager: MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT"
  assert_line "eGPU variables left in system manager: none"
  assert_line "eGPU variables found in user manager: $EGPU_NAMES"
  assert_line "eGPU variables left in user manager: none"
  assert_called "$(as_user show-environment)"
}

@test "GBM_BACKEND and __GLX_VENDOR_LIBRARY_NAME with other values: left alone" {
  set_os steamos
  manager_env user "GBM_BACKEND=foo" "__GLX_VENDOR_LIBRARY_NAME=mesa" "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  manager_env system "GBM_BACKEND=foo" "__GLX_VENDOR_LIBRARY_NAME=mesa"
  run_clean
  assert_success
  assert_equal "$(manager_env_of user)" "$(printf '%s\n' "GBM_BACKEND=foo" "__GLX_VENDOR_LIBRARY_NAME=mesa")"
  assert_equal "$(manager_env_of system)" "$(printf '%s\n' "GBM_BACKEND=foo" "__GLX_VENDOR_LIBRARY_NAME=mesa")"
  refute_called "systemctl unset-environment GBM_BACKEND"
  refute_called "systemctl unset-environment __GLX_VENDOR_LIBRARY_NAME"
  refute_called "systemctl --user unset-environment GBM_BACKEND"
  refute_called "systemctl --user unset-environment __GLX_VENDOR_LIBRARY_NAME"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "eGPU variables found in user manager: KWIN_DRM_DEVICES"
  assert_line "eGPU variables left in user manager: none"
  assert_line "eGPU variables found in system manager: none"
}

@test "GBM_BACKEND and __GLX_VENDOR_LIBRARY_NAME with values that only start like ours: left alone" {
  set_os cachyos
  manager_env user "GBM_BACKEND=nvidia-drm-x" "__GLX_VENDOR_LIBRARY_NAME=nvidia2"
  run_clean
  assert_success
  assert_equal "$(manager_env_of user)" "$(printf '%s\n' "GBM_BACKEND=nvidia-drm-x" "__GLX_VENDOR_LIBRARY_NAME=nvidia2")"
  refute_called "systemctl --user unset-environment GBM_BACKEND"
  refute_called "systemctl --user unset-environment __GLX_VENDOR_LIBRARY_NAME"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "eGPU variables found in user manager: none"
}

@test "quoted values from show-environment are still recognized as ours" {
  set_os cachyos
  manager_env user "GBM_BACKEND=\$'nvidia-drm'" "__GLX_VENDOR_LIBRARY_NAME=\"nvidia\"" "VK_LOADER_LAYERS_DISABLE=\$'*'"
  run_clean
  assert_success
  assert_equal "$(manager_env_of user)" ""
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "eGPU variables found in user manager: GBM_BACKEND __GLX_VENDOR_LIBRARY_NAME VK_LOADER_LAYERS_DISABLE"
}

@test "user manager not running (no runtime dir): logged explicitly, system manager still cleaned, exit 0" {
  set_os cachyos
  no_user_session
  manager_env system "${EGPU_ENV[@]:0:5}"
  run_clean
  assert_success
  assert_equal "$(manager_env_of system)" ""
  refute_called "systemctl --user"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "eGPU variables left in system manager: none"
  assert_line "eGPU variables left in user manager: not checked (the user manager for xgmtest isn't running: no $ROOT/run/user/64999)"
}

@test "user manager doesn't answer: logged as unknown, the variables that are always ours still unset, exit 0" {
  set_os cachyos
  user_manager_down
  run_clean
  assert_success
  assert_called "systemctl --user unset-environment KWIN_DRM_DEVICES"
  refute_called "systemctl --user unset-environment GBM_BACKEND"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "eGPU variables found in user manager: unknown (couldn't read it: Failed to connect to bus: No such file or directory)"
  assert_line "eGPU variables left in user manager: unknown (couldn't read it: Failed to connect to bus: No such file or directory)"
  # The unsets that are tried anyway don't add their own errors.
  assert_equal "$(grep -c "Failed to connect to bus" "$LOG_DIR/desktop_eject_request.log")" 2
}

@test "appends to desktop_eject_request.log" {
  set_os steamos
  echo "[12:00:00] Desktop Icon triggered Eject" > "$LOG_DIR/desktop_eject_request.log"
  KEEP_LOG_DIR=1 run_clean
  assert_success
  assert_equal "$(head -n 1 "$LOG_DIR/desktop_eject_request.log")" "[12:00:00] Desktop Icon triggered Eject"
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
}

@test "bazzite: skipped (the image owns GBM_BACKEND/__GLX_VENDOR_LIBRARY_NAME), nothing unset" {
  set_os bazzite-nvidia
  manager_env user "GBM_BACKEND=nvidia-drm" "__GLX_VENDOR_LIBRARY_NAME=nvidia"
  run_clean
  assert_success
  refute_called "systemctl"
  assert_equal "$(manager_env_of user)" "$(printf '%s\n' "GBM_BACKEND=nvidia-drm" "__GLX_VENDOR_LIBRARY_NAME=nvidia")"
  [[ "$LOG" == *"bazzite-nvidia: egpu-enable doesn't inject the eGPU environment here. Skipping."* ]]
}

# The wait for the user's new graphical session (xgm_wait_for_user_session), before anything is read.
@test "user session ready right away: no wait, logged as 0.00s, then cleaned" {
  set_os steamos
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  refute_called "sleep"
  assert_called_before "systemctl --user is-active graphical-session.target" "systemctl --user show-environment"
  [[ "$LOG" == *"user session ready after 0.00s (session 2)"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "graphical session ready after 3 checks: waits 0.03s, then cleans what the session imported" {
  set_os steamos
  session_ready 3
  manager_env user "GBM_BACKEND=nvidia-drm"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 3
  assert_equal "$(grep -cFx "systemctl --user is-active graphical-session.target" "$SHIM_LOG")" 4
  assert_called_before "sleep 0.01" "systemctl --user show-environment"
  [[ "$LOG" == *"user session ready after 0.03s (session 2)"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "graphical session activating for 5 checks: keeps waiting, ready after 0.05s" {
  set_os cachyos
  session_ready activating:5
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 5
  [[ "$LOG" == *"user session ready after 0.05s (session 2)"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "graphical session never ready: gives up at the cap, names what's missing, cleans anyway" {
  set_os cachyos
  session_ready never
  manager_env user "MESA_VK_DEVICE_SELECT=10de:2717"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 20
  [[ "$LOG" == *"user session not ready after 0.2s (graphical-session.target is inactive), continuing anyway"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "user manager not answering, or no runtime dir: keeps waiting until the cap, exit 0" {
  set_os cachyos
  user_manager_down
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 20
  [[ "$LOG" == *"user session not ready after 0.2s (graphical-session.target is not answering), continuing anyway"* ]]

  : > "$SHIM_LOG"
  rm -f "$SHIM_STATE/user_manager_down" "$SHIM_STATE/ticks"
  no_user_session
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 20
  refute_called "systemctl --user"
  [[ "$LOG" == *"user session not ready after 0.2s (no $ROOT/run/user/64999/bus), continuing anyway"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: not checked (the user manager for xgmtest isn't running: no $ROOT/run/user/64999)"* ]]
}

# Step 0, exp 2 (SteamOS): the eject stopped sddm, logind removed login session 1 and then the old
# user manager (and its Class=manager session 2). sddm starts again, the new login session 3
# appears, then the new manager, its bus, and graphical-session.target. 6c1a24c returned at once
# because there was no runtime dir, and steamos-session-select found no user bus.
@test "exp 2: no runtime dir, then the new session, manager, bus and graphical session: waits for all, then cleans" {
  set_os steamos
  timeline sessions "0 2:manager:closing" "2 3:user:online" "3 3:user:active 4:manager:active"
  timeline manager "0 inactive" "3 activating" "4 active"
  timeline rundir "0 absent" "3 present"
  timeline bus "0 absent" "5 present"
  timeline graphical "0 inactive" "6 active"
  # The capture showed the new manager starting with a long job queue.
  timeline jobs "0 30" "7 0"
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean "1 2"
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 7
  [[ "$LOG" == *"user session ready after 0.07s (session 3)"* ]]
  [ "$(line_last "sleep 0.01")" -lt "$(line_first "systemctl --user show-environment")" ]
  run grep -n -e "user session ready" -e "eGPU variables found in user manager" "$LOG_DIR/desktop_eject_request.log"
  assert_line --index 0 --partial "user session ready after 0.07s (session 3)"
  assert_line --index 1 --partial "eGPU variables found in user manager: KWIN_DRM_DEVICES"
  assert_equal "$(manager_env_of user)" ""
  refute_called "systemctl kill"
  refute_called "systemctl --user kill"
}

# Pass 3 (SteamOS): the old user manager hung in "deactivating" for 90 s, because
# xdg-document-portal.service couldn't stop (a fusermount3 child stayed alive).
@test "pass 3: old manager stuck stopping: ends its stuck units after XGM_HUNG_AFTER, then kills it, once each" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating"
  manager_after kill "0 inactive" "2 active"
  timeline sessions "0 2:manager:closing" "1 3:user:active"
  stuck_unit xdg-document-portal.service
  doc_mounted
  run_clean "1 2"
  assert_success

  local fuse unit_kill manager_kill
  fuse=$(line_first "fusermount3 -uz $ROOT/run/user/64999/doc")
  unit_kill=$(line_first "systemctl --user kill -s KILL -- xdg-document-portal.service")
  manager_kill=$(line_first "systemctl kill -s KILL user@64999.service")
  [ "$fuse" -gt 0 ] && [ "$unit_kill" -gt "$fuse" ] && [ "$manager_kill" -gt "$unit_kill" ] \
    || fail "expected fusermount3 ($fuse), then the unit kill ($unit_kill), then the manager kill ($manager_kill)"
  # Not before XGM_HUNG_AFTER (5 checks), and the manager XGM_HUNG_AFTER after the unit.
  assert_equal "$(count_before "sleep 0.01" "$fuse")" 5
  assert_equal "$(( $(count_before "sleep 0.01" "$manager_kill") - $(count_before "sleep 0.01" "$unit_kill") ))" 5
  assert_called "$(as_user list-units --state=deactivating --no-legend --plain)"
  assert_equal "$(grep -cFx "systemctl kill -s KILL user@64999.service" "$SHIM_LOG")" 1
  assert_equal "$(grep -c "^systemctl --user kill" "$SHIM_LOG")" 1
  assert_equal "$(grep -c "^fusermount3" "$SHIM_LOG")" 1
  assert_called "timeout -s KILL 2 fusermount3 -uz $ROOT/run/user/64999/doc"

  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "old user manager still stopping after 0.05s; ending its stuck units"
  assert_line "killed stuck unit: xdg-document-portal.service"
  assert_line "old user manager still stopping; killing it"
  assert_equal "$(grep -c "old user manager still stopping" "$LOG_DIR/desktop_eject_request.log")" 2
  assert_line "user session ready after 0.12s (session 3)"
}

# On hardware a check of a hung manager can take seconds (each call can run into its 2 s
# timeout), so the waits go by the clock, not by the number of polls.
@test "hung manager whose every call takes 2 s: kill steps and the cap go by clock time, not polls" {
  set_os steamos
  export XGM_WAIT_POLL=0.25 XGM_HUNG_AFTER=5 XGM_WAIT_CAP=20
  timeline manager "0 deactivating"
  timeline sessions "0 2:manager:closing" "1 3:user:active"
  stuck_unit xdg-document-portal.service
  manager_call_cost 2
  run_clean "1 2"
  assert_success

  local unit_kill manager_kill
  unit_kill=$(line_first "systemctl --user kill -s KILL -- xdg-document-portal.service")
  manager_kill=$(line_first "systemctl kill -s KILL user@64999.service")
  [ "$unit_kill" -gt 0 ] && [ "$manager_kill" -gt "$unit_kill" ] || fail "expected the unit kill ($unit_kill), then the manager kill ($manager_kill)"
  # First seen stopping at 2.00 s; 3 polls later the clock is at 8.75 s (6.75 s of it stopping),
  # where counting polls would have needed 20 (5 s / 0.25 s).
  assert_equal "$(count_before "sleep 0.25" "$unit_kill")" 3
  # Step 1's three calls (recheck, list-units, kill) end at 14.75 s; the manager kill comes 3 polls
  # later (the iteration that starts at 19.50 s).
  assert_equal "$(( $(count_before "sleep 0.25" "$manager_kill") - $(count_before "sleep 0.25" "$unit_kill") ))" 3
  # The 20 s cap is clock time: 6 polls, not 80. The last iteration starts before 20 s and makes
  # at most 3 calls of 2 s each (show, recheck, kill).
  assert_equal "$(calls_matching "sleep 0.25" | wc -l)" 6
  awk -v c="$(cat "$SHIM_STATE/clock")" 'BEGIN { exit !(c >= 1020 && c < 1026.25) }' \
    || fail "the wait gave up at clock $(cat "$SHIM_STATE/clock") (started at 1000), expected within one iteration after 20 s"

  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "old user manager still stopping after 6.75s; ending its stuck units"
  assert_line "killed stuck unit: xdg-document-portal.service"
  assert_line "old user manager still stopping; killing it"
  assert_line "user session not ready after 20s (user@64999.service is deactivating), continuing anyway"
  assert_equal "$(grep -c "old user manager still stopping" "$LOG_DIR/desktop_eject_request.log")" 2
}

@test "old manager stops once its stuck unit is killed: the manager itself isn't killed" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating"
  manager_after unit-kill "1 inactive" "2 active"
  timeline sessions "0 2:manager:closing" "1 3:user:active"
  stuck_unit xdg-document-portal.service
  run_clean "1 2"
  assert_success
  assert_called "systemctl --user kill -s KILL -- xdg-document-portal.service"
  refute_called "systemctl kill"
  refute_called "fusermount3"
  [[ "$LOG" == *"user session ready after 0.07s (session 3)"* ]]
  [[ "$LOG" != *"killing it"* ]]
}

# The kill steps only ever hit the manager that was seen stopping (its InvocationID).
@test "the manager changes between list-units and the kills: the remaining units aren't killed" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating:old"
  manager_after list-units "0 active:new"
  timeline sessions "0 2:manager:closing" "1 3:user:active"
  stuck_unit xdg-document-portal.service
  stuck_unit app-steam@autostart.service
  run_clean "1 2"
  assert_success
  assert_called "$(as_user list-units --state=deactivating --no-legend --plain)"
  refute_called "systemctl --user kill"
  refute_called "systemctl kill"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "old user manager gone; not killing xdg-document-portal.service"
  refute_line --partial "killed stuck unit"
  refute_line --partial "not killing app-steam@autostart.service"
  assert_line "user session ready after 0.06s (session 3)"
}

@test "the manager changes right before the step-2 kill: the new one isn't killed and gets its own time" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating:old"
  # Shows 1-11 are the checks of ticks 0-10 (step 1 at tick 5 has no units, so no recheck); the
  # 12th is step 2's recheck, which finds a new manager.
  manager_after show:11 "0 deactivating:new" "2 active:new"
  timeline sessions "0 2:manager:closing" "1 3:user:active"
  run_clean "1 2"
  assert_success
  refute_called "systemctl kill"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "old user manager still stopping after 0.05s; ending its stuck units"
  assert_line "old user manager gone; not killing user@64999.service"
  refute_line "old user manager still stopping; killing it"
  assert_line "user session ready after 0.12s (session 3)"
}

@test "the old manager ends and a new one starts stopping: the new one gets its own XGM_HUNG_AFTER, then step 2" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating:old"
  # The old manager's step 1 (tick 5) ends it; a new one comes up at tick 7 and is stopping at 8.
  manager_after unit-kill "1 inactive" "2 active:new" "3 deactivating:new"
  timeline sessions "0 2:manager:closing"
  stuck_unit xdg-document-portal.service
  run_clean "1 2"
  assert_success
  local list="systemctl --user list-units --state=deactivating --no-legend --plain"
  local kill="systemctl kill -s KILL user@64999.service"
  assert_equal "$(grep -cFx "$list" "$SHIM_LOG")" 2
  # The old manager's step 1 at tick 5, the new one's 5 polls after it was first seen stopping
  # (tick 8), and its step 2 another 5 polls later. Without the reset, the kill came at tick 10.
  assert_equal "$(count_before "sleep 0.01" "$(line_first "$list")")" 5
  assert_equal "$(count_before "sleep 0.01" "$(line_last "$list")")" 13
  assert_equal "$(count_before "sleep 0.01" "$(line_first "$kill")")" 18
  assert_equal "$(grep -cFx "$kill" "$SHIM_LOG")" 1
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_equal "$(grep -c "old user manager still stopping after 0.05s; ending its stuck units" "$LOG_DIR/desktop_eject_request.log")" 2
  assert_line "old user manager still stopping; killing it"
}

@test "a session that's still opening doesn't count, while the hung old manager is still ended" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05
  timeline manager "0 deactivating:old"
  timeline sessions "0 2:manager:closing 3:user:opening"
  stuck_unit xdg-document-portal.service
  run_clean "1 2"
  assert_success
  assert_called "systemctl --user kill -s KILL -- xdg-document-portal.service"
  assert_called "systemctl kill -s KILL user@64999.service"
  [[ "$LOG" == *"user session not ready after 0.2s (no new user session for xgmtest), continuing anyway"* ]]
}

@test "fast eject: the old manager stays active and a new user session appears: ready, nothing killed" {
  set_os steamos
  timeline sessions "0 2:user:active" "2 2:user:closing" "3 5:user:active"
  run_clean "2"
  assert_success
  [[ "$LOG" == *"user session ready after 0.03s (session 5)"* ]]
  refute_called "systemctl kill"
  refute_called "systemctl --user kill"
  refute_called "fusermount3"
}

@test "only the known session, a manager, a closing, a greeter and another user's session: not ready, the cap names it" {
  set_os steamos
  timeline sessions "0 2:user:active 3:manager:active 4:user:closing 6:greeter:online 7:user:active:someone"
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean "2"
  assert_success
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 20
  [[ "$LOG" == *"user session not ready after 0.2s (no new user session for xgmtest), continuing anyway"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
}

@test "jobs queued in the user manager: not ready until they're done" {
  set_os steamos
  timeline jobs "0 2" "4 0"
  run_clean
  assert_success
  [[ "$LOG" == *"user session ready after 0.04s (session 2)"* ]]
  assert_equal "$(grep -cFx "systemctl --user list-jobs --no-legend" "$SHIM_LOG")" 5

  : > "$SHIM_LOG"
  rm -f "$SHIM_STATE/ticks"
  timeline jobs "0 1"
  run_clean
  assert_success
  [[ "$LOG" == *"user session not ready after 0.2s (the user manager has jobs queued), continuing anyway"* ]]
}

@test "user manager stopping at cleanup time: logged, its environment not read" {
  set_os steamos
  export XGM_HUNG_AFTER=10
  timeline manager "0 deactivating"
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  refute_called "systemctl --user show-environment"
  refute_called "systemctl kill"
  run cat "$LOG_DIR/desktop_eject_request.log"
  assert_line "user session not ready after 0.2s (user@64999.service is deactivating), continuing anyway"
  assert_line "eGPU variables left in system manager: none"
  assert_line "eGPU variables left in user manager: not checked (the user manager for xgmtest is stopping; its environment won't carry over)"
}

@test "user manager calls go through setpriv with a 2 s timeout, never sudo or runuser" {
  set_os steamos
  run_clean
  assert_success
  assert_called "timeout -s KILL 2 $(as_user is-active graphical-session.target)"
  assert_called "timeout -s KILL 2 $(as_user list-jobs --no-legend)"
  assert_called "timeout -s KILL 2 $(as_user show-environment)"
  assert_called "timeout -s KILL 2 $(as_user unset-environment KWIN_DRM_DEVICES)"
  refute_called "sudo"
  refute_called "runuser"
}

# _xgm_now: the fake clock file in tests, else the wall clock ($EPOCHREALTIME or date).
clock_probe() {
  printf '%s\n' '#!/bin/bash' ". '$XGM_REPO/bin/xgm-common.sh'" "$1" > "$BATS_TEST_TMPDIR/probe"
  run env -i PATH="$SYSBIN" ${2:+XGM_FAKE_CLOCK="$2"} "$SYSBIN/bash" "$BATS_TEST_TMPDIR/probe"
}

@test "_xgm_now / _xgm_now_cs: fake clock file, else the wall clock" {
  echo 12.345678 > "$BATS_TEST_TMPDIR/clock"
  clock_probe 'echo "$(_xgm_now) $(_xgm_now_cs)"' "$BATS_TEST_TMPDIR/clock"
  assert_success
  assert_output "12.345678 1234"

  echo 7 > "$BATS_TEST_TMPDIR/clock"
  clock_probe '_xgm_now_cs' "$BATS_TEST_TMPDIR/clock"
  assert_output "700"

  # No fake clock: the real one, in seconds since the epoch, moving forward.
  clock_probe 'a=$(_xgm_now_cs); b=$(_xgm_now_cs); echo "$a $b"'
  assert_success
  local a b
  read -r a b <<< "$output"
  [ "$a" -gt 170000000000 ] && [ "$b" -ge "$a" ] || fail "unexpected clock: $output"
}

# NTP can step the wall clock back during the wait.
@test "clock steps back 1 s during the wait: the time already waited counts, the cap is exactly 20 polls" {
  set_os steamos
  session_ready never
  clock_step 5 -1
  run_clean
  assert_success
  # Not 25 (restarting the cap at the step) nor 120 (a stale start).
  assert_equal "$(calls_matching "sleep 0.01" | wc -l)" 20
  [[ "$LOG" == *"user session not ready after 0.2s (graphical-session.target is inactive), continuing anyway"* ]]
}

@test "clock steps back while the old manager is stopping: the time it's been stopping counts, step 1 at tick 5" {
  set_os steamos
  export XGM_HUNG_AFTER=0.05 XGM_WAIT_CAP=1
  timeline manager "0 deactivating:old"
  timeline sessions "0 2:manager:closing"
  stuck_unit xdg-document-portal.service
  clock_step 3 -1
  run_clean "1 2"
  assert_success
  # Seen stopping at 1000, back to 999.03 at tick 3: still step 1 after 5 polls, as without the step.
  assert_equal "$(count_before "sleep 0.01" "$(line_first "systemctl --user kill -s KILL -- xdg-document-portal.service")")" 5
}

@test "setpriv missing: logged once, the user manager calls fall back to sudo -u, with a timeout outside and inside sudo" {
  set_os steamos
  no_setpriv
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  assert_called "timeout -s KILL 2 sudo -u xgmtest XDG_RUNTIME_DIR=/run/user/64999 timeout -s KILL 2 systemctl --user is-active graphical-session.target"
  assert_called "timeout -s KILL 2 sudo -u xgmtest XDG_RUNTIME_DIR=/run/user/64999 timeout -s KILL 2 systemctl --user show-environment"
  refute_called "setpriv"
  assert_equal "$(manager_env_of user)" ""
  assert_equal "$(grep -c "setpriv not found; using sudo -u" "$LOG_DIR/desktop_eject_request.log")" 1
  [[ "$LOG" == *"user session ready after 0.00s (session 2)"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
}
