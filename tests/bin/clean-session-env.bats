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
}

run_clean() { run_script clean-session-env xgmtest "$LOG_DIR"; }

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
  assert_called "sudo -u xgmtest XDG_RUNTIME_DIR=/run/user/64999 systemctl --user show-environment"
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

# The wait for the user's graphical session (graphical-session.target), before anything is read.
@test "user session ready right away: no wait, logged as 0s, then cleaned" {
  set_os steamos
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  refute_called "sleep"
  assert_called_before "systemctl --user is-active graphical-session.target" "systemctl --user show-environment"
  [[ "$LOG" == *"user session ready after 0s"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "user session ready after 3 checks: waits 1.5s, then cleans what the session imported" {
  set_os steamos
  session_ready 3
  manager_env user "GBM_BACKEND=nvidia-drm"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.5" | wc -l)" 3
  assert_equal "$(grep -cFx "systemctl --user is-active graphical-session.target" "$SHIM_LOG")" 4
  assert_called_before "sleep 0.5" "systemctl --user show-environment"
  [[ "$LOG" == *"user session ready after 1.5s"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "user session activating for 5 checks: keeps waiting (not 'not answering'), ready after 2.5s" {
  set_os cachyos
  session_ready activating:5
  manager_env user "KWIN_DRM_DEVICES=/dev/dri/card1:/dev/dri/card0"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.5" | wc -l)" 5
  assert_equal "$(grep -cFx "systemctl --user is-active graphical-session.target" "$SHIM_LOG")" 6
  [[ "$LOG" == *"user session ready after 2.5s"* ]]
  [[ "$LOG" != *"user manager not answering"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "user session never ready: gives up after 10s and cleans anyway" {
  set_os cachyos
  session_ready never
  manager_env user "MESA_VK_DEVICE_SELECT=10de:2717"
  run_clean
  assert_success
  assert_equal "$(calls_matching "sleep 0.5" | wc -l)" 20
  [[ "$LOG" == *"user session not ready after 10s, cleaning anyway"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: none"* ]]
  assert_equal "$(manager_env_of user)" ""
}

@test "user manager not running or not answering: no wait" {
  set_os cachyos
  user_manager_down
  run_clean
  assert_success
  refute_called "sleep"
  [[ "$LOG" == *"user manager not answering; not waiting for the user session"* ]]

  : > "$SHIM_LOG"
  rm -f "$SHIM_STATE/user_manager_down"
  no_user_session
  run_clean
  assert_success
  refute_called "sleep"
  refute_called "systemctl --user"
  [[ "$LOG" != *"user session"* ]]
  [[ "$LOG" == *"eGPU variables left in user manager: not checked (the user manager for xgmtest isn't running: no $ROOT/run/user/64999)"* ]]
}
